package Plugins::iBroadcast::ProtocolHandler;

# Logitech Media Server Copyright 2005-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use base qw(Slim::Player::Protocols::HTTPS);

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;

use Data::Dumper;

use Plugins::iBroadcast::API;

my $log   = logger('plugin.ibroadcast');
my $prefs = preferences('plugin.ibroadcast');

use constant CAN_GETOBJECTFORURL => (Slim::Utils::Versions->compareVersions($::VERSION, '9.1.0') >= 0);

# remove podcast:// protocol to scan real url
sub scanUrl {
	my ( $class, $url, $args ) = @_;

	my $song = $args->{song};
	my $httpUrl = _resolveUrl($url);
	main::DEBUGLOG && $log->is_debug && $log->debug("Resolved ibcst url $url => $httpUrl");
	my $cb = $args->{cb};	
	
	$args->{cb} = sub {
		my $track = shift;

		if ($track) {
			main::INFOLOG && $log->info("Scanned ibcst $url => ", $track->url);

			# use the scanned track to get streamable url, ignore scanned title and coverart
			$song->streamUrl($track->url);
			
			my $format = $track->content_type;			
			$song->pluginData('format', $format);			

			my $bitrate = $track->bitrate();			
			$song->bitrate($bitrate);
			main::DEBUGLOG && $log->is_debug && $log->debug("bitrate is : $bitrate format :  $format");							
			
			# reset track's url - from now on all $url-based requests will refer to that track
			$track->url($url);
		}

		$cb->($track, @_);
	};

	$class->SUPER::scanUrl($httpUrl, $args);
}

sub new {
	my ($class, $args) = @_;

	# use streaming url but avoid redirection loop
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	return $class->SUPER::new( $args );
}

sub audioScrobblerSource { 'P' }

sub formatOverride {
	my ($class, $song) = @_;
	#just return mp3 for now
	my $format = $song->pluginData('format');
	return $format;
}

sub onStream {
	my ($self, $client, $song) = @_;

	my $url = $song->currentTrack->url;

	main::DEBUGLOG && $log->is_debug && $log->debug("url:$url");
	my $trackid = _getTrackIDFromUrl($url);

	
	main::DEBUGLOG && $log->is_debug && $log->debug("Recording play for trackid $trackid");

	Plugins::iBroadcast::API::statusHistoryRecord(
		$trackid,
		time(),
		sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("Recorded play for trackid $trackid");
	
		},
		sub {
			$log->error("Failed to record play for trackid $trackid: @_");	
		}		
	);
	
}

sub getMetadataFor {
	my ( $class, $client, $url, undef, $song ) = @_;

	my $meta;

	if ( $client && ($song ||= $client->currentSongForUrl($url)) ) {
		#The metadata might already be on the song
		if ( $meta = $song->pluginData('meta') ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Returning meta data from song");
			return $meta;
		}
	}

	my $track;
	if (CAN_GETOBJECTFORURL) {# if LMS is version is < 9.1 we can call libraryObjectForUrl, if not we have to be naughty and bypass it.
		main::DEBUGLOG && $log->is_debug && $log->debug("Getting track from libraryObjectForUrl");
		$track = Slim::Schema->libraryObjectForUrl($url);
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("Getting track directly from _retreiveTrack");
		$track = Slim::Schema->_retrieveTrack($url,0,1);
	}

	if ($track) {
		$meta = {
				artist => $track->artistName,
				album  => $track->album->title,
				title  => $track->title,				
				duration => $track->secs,
				secs   => $track->secs,
				cover  => $track->cover,
				tracknum => $track->tracknum,
				year => $track->year,
				type => 'ibcst',
		};
	} else { 
		main::DEBUGLOG && $log->is_debug && $log->debug("Track not available adding some kind of meta");
		$meta = {				
				title  => $url,	
				type => 'ibcst',							
		};		
	}

	main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($meta));
	if ( $client && ($song ||= $client->currentSongForUrl($url)) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Adding meta data to song");
		$song->pluginData('meta', $meta);
	}
	return $meta;
}


sub _resolveUrl {
	my ($url) = @_;	

	if ($url =~ m{^ibcst://(.+)$}) {
		my $file = $1;

		my @fileParts = split(/_/, $file);
		if (scalar(@fileParts) != 2) {
			$log->warn("Invalid ibcst url, missing file or trackid: $url");
			return undef;
		} else {
			$file = _addbitrate($fileParts[0]);
			my $trackid = $fileParts[1];
		
			my $usertoken = $prefs->get('usertoken');
			my $userid = $prefs->get('userid');
			my $expire = time();
			if ($usertoken) {
				return "https://streaming.ibroadcast.com/$file?expires=$expire&signature=$usertoken&user_id=$userid&file_id=$trackid&platform=LMS_iBroadcast_Plugin";
			} else {
				$log->warn("No usertoken, cannot resolve ibcst url");
				return undef;
			}
		}
	} else {
		$log->warn("Invalid ibcst url: $url");
		return undef;
	}
}

sub _addbitrate {
	my ($url) = @_;

	my $btrate = $prefs->get('bitrate') || '128';

	main::DEBUGLOG && $log->is_debug && $log->debug("Preferred bitrate is $btrate");

	#replace the {bitrate} token with the preferred bitrate
	$url =~ s/{bitrate}/$btrate/g;

	return $url;
}


sub _getTrackIDFromUrl {
	my ($url) = @_;
	
	if ($url =~ m{^ibcst://(.+)$}) {
		my $file = $1;

		my @fileParts = split(/_/, $file);
		if (scalar(@fileParts) != 2) {
			$log->warn("Invalid ibcst url, missing file or trackid: $url");
			return undef;
		} else {
			return $fileParts[1];
		}
	} else {
		$log->warn("Invalid ibcst url: $url");
		return undef;
	}
}

1;
