package Plugins::iBroadcast::Importer;

use strict;

use base qw(Slim::Plugin::OnlineLibraryBase);

use Date::Parse qw(str2time);
use Digest::MD5 qw(md5_hex);
use List::Util qw(max);
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Cache;
use Slim::Utils::Prefs;


use Plugins::iBroadcast::API;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);


my $cache = Slim::Utils::Cache->new();

my $log = logger('plugin.ibroadcast');

sub initPlugin {
	my $class = shift;
	$log->error('Init the importer');

	if (!CAN_IMPORTER) {
		$log->warn('The library importer feature requires at least Logitech Media Server 8.');
		return;
	}

	$class->SUPER::initPlugin(@_)
}

sub startScan { 
	my $class = shift;

	$log->error('iBroadcast library import started');
	main::DEBUGLOG && $log->is_debug && $log->debug("Starting iBroadcast library scan");

	if ( my $library = Plugins::iBroadcast::API::getLibrarySync() ) {
		main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($library));
		
		main::DEBUGLOG && $log->is_debug && $log->debug("Got library");

		$class->scanAlbums($library);

		$class->scanArtists($library);
		
		$class->deleteRemovedTracks();

		my $lastmodified = $library->{status}->{lastmodified};
		main::DEBUGLOG && $log->is_debug && $log->debug("Library last modified: " . ($lastmodified || 'never'));
		$cache->set( 'ibcst_libraryupdated', $lastmodified, 86400 *30 ); # 30 days

	} else {
		
		$log->warn('Could not get library');
		
		
	}	

	Slim::Music::Import->endImporter($class);

}


sub scanAlbums {
	my ($class,$library) = @_;

	#Albums
		my $albums = $library->{library}{albums};
		my @album_ids = grep { $_ ne 'map' } keys %$albums;
		my $map	= $albums->{map};

		$class->initOnlineTracksTable();

	
		main::DEBUGLOG && $log->is_debug && $log->debug("Albums" . Dumper($albums) );

		my $progress;
		foreach my $album_id (@album_ids) {
			my $album = $albums->{$album_id};
			main::DEBUGLOG && $log->is_debug && $log->debug("Album" . Dumper($album) );
			$class->scanAlbum($album,$map,$library,$progress);
		}
		$progress->final() if $progress;
		main::SCANNER && Slim::Schema->forceCommit;

}

sub scanArtists {
	my ($class,$library) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'iBroadcast Tracks',
		'total' => 1,
		'every' => 1,
	});

		# backwards compatibility for 8.1 and older...
	my $contributorNameNormalizer;
	if ($class->can('normalizeContributorName')) {
		$contributorNameNormalizer = sub {
			$class->normalizeContributorName($_[0]);
		};
	}
	else {
		$contributorNameNormalizer = sub { $_[0] };
	}

	#Artists
	my $artists = $library->{library}{artists};
	my @artist_ids = grep { $_ ne 'map' } keys %$artists;
	my $map	= $artists->{map};

	main::DEBUGLOG && $log->is_debug && $log->debug("Artists" . Dumper($artists) );

	foreach my $artist_id (@artist_ids) {
		my $artist = $artists->{$artist_id};	

		if (scalar @{$artist->[$map->{tracks}]}) {  #only add artists if they have tracks
			main::DEBUGLOG && $log->is_debug && $log->debug("Artist" . Dumper($artist) );	
			$progress->update($artist->[$map->{name}] || 'Unknown Artist');
			Slim::Schema::Contributor->add({
				'artist' => $contributorNameNormalizer->($artist->[$map->{name}]),
				'extid'  => 'ibcst:artist:' . $artist_id
			});
		}
	}
	Slim::Schema->forceCommit if main::SCANNER;
	$progress->final();
	Slim::Schema->forceCommit;

}


sub scanAlbum {
	my ($class, $album, $albumMap, $library, $progress) = @_;

	if ($progress) {
		$progress->total($progress->total + 1);
	}
	else {
		$progress = Slim::Utils::Progress->new({
			'type'  => 'importer',
			'name'  => 'iBroadcast Tracks',
			'total' => 1,
			'every' => 1,
		});
	}

	main::INFOLOG && $log->is_info && $log->info("Reading tracks...");	

	$progress->update($album->[$albumMap->{name}] || string('PLUGIN_IBROADCAST_UNKNOWN_ALBUM'));

	my $preparedTracks = [];	
	
	foreach my $trackid (@{$album->[$albumMap->{tracks}] || []}) {
		my $track = $library->{library}->{tracks}->{$trackid};
		my $trackMap = $library->{library}->{tracks}->{map};

		my $artist = $library->{library}->{artists}->{$track->[$trackMap->{artist_id}]};
		my $artistName = $artist->[$library->{library}->{artists}->{map}->{name}];


		my $composer;
		if (my $additionalArtists = $track->[$trackMap->{artists_additional}]) {
			foreach my $additionalArtist (@{$additionalArtists}) {
				if ($additionalArtist->[$trackMap->{artists_additional_map}->{type}] eq 'composer') {
					$composer =  $library->{library}->{artists}->{$additionalArtist->[$trackMap->{artists_additional_map}->{artist_id}]}->[$library->{library}->{artists}->{map}->{name}];
					main::DEBUGLOG && $log->is_debug && $log->debug("Composer found: $composer");
					last;
				}
			}

		}

		push @$preparedTracks, _prepareTrack($trackid, $library->{library}->{tracks}->{$trackid},  $library->{library}->{tracks}->{map}, $album->[$albumMap->{name}], $artistName,  $album->[$albumMap->{disc}], $composer);

	}
	main::DEBUGLOG && $log->is_debug && $log->debug("Prepared " . scalar(@$preparedTracks) . " tracks for album " . $album->[$albumMap->{name}] );
	main::DEBUGLOG && $log->is_debug && $log->debug(Dumper(@{$preparedTracks}) );
	$class->storeTracks($preparedTracks);    
	return;
}

sub _prepareTrack {
	my ($trackid, $track, $map, $albumName, $artistName, $disc, $composer) = @_;

	my $splitChar = substr(preferences('server')->get('splitList'), 0, 1);

	my $url = 'ibcst://' . _replacebitratewithtoken($track->[$map->{file}]) . '_' . $trackid;

	
	my $preparedTrack = {
	
		url          => $url,
		TITLE        => $track->[$map->{title}],
		ARTIST       => $artistName,
		ARTIST_EXTID => 'ibcst:artist:' .$track->[$map->{artist_id}],	
		TRACKARTIST  => $artistName,
		ALBUM        => $albumName,		
		ALBUM_EXTID  => 'ibcst:album:' . $track->[$map->{album_id}],
		TRACKNUM     => $track->[$map->{track}],	
		GENRE        => $track->[$map->{genre}],	
		DISC         => 1,
		DISCC        => 1,
		SECS         => $track->[$map->{length}],
		YEAR         => $track->[$map->{year}],
		COVER        => 'https://artwork.ibroadcast.com/artwork/' . $track->[$map->{artwork_id}] . '-300',
		AUDIO        => 1,
		EXTID        => $url,	
		TIMESTAMP    => str2time($track->[$map->{uploaded_on}] || 0),
		CONTENT_TYPE => 'ibcst'
	};

	if ($composer) {
		$preparedTrack->{COMPOSER} = $composer;
	}

	return $preparedTrack;
}

sub _replacebitratewithtoken {
	my ($url) = @_;
	#replace the the part before the second / with a {bitrate} token and remove the leading /
	#eg: /128/sdfs/ewrewr/erer  with {bitrate}/sdfs/ewrewr/erer
	if ($url =~ m{^/[^/]+/(.+)$}) {
		return '{bitrate}/' . $1;
	}
	
	return $url;
}



# This code is not run in the scanner, but in LMS

sub needsUpdate {
	my ($class, $cb) = @_;
	

    Plugins::iBroadcast::API::getLibraryStatus(
        sub {
            my $JSON=shift;
            my $lastupdated = $cache->get('ibcst_libraryupdated');
            my $updated = $JSON->{status}->{lastmodified} || 0;
			
			main::DEBUGLOG && $log->is_debug && $log->debug("Library last updated: " . ($lastupdated || 'never') . ", current: " . ($updated || 'unknown'));
            if ($updated && $lastupdated && ($updated eq $lastupdated)) {
                main::DEBUGLOG && $log->is_debug && $log->debug('library not changed since last import');
                $cb->(0);
                return;
            }
            main::DEBUGLOG && $log->is_debug && $log->debug('Need to update library');            

            $cb->(1);
        },
        sub {
            $log->warn('Could not get library status');
            $cb->(0);
        }
    );
    
}

sub trackUriPrefix { 'ibcst://' }


1;