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


sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}


# To support remote streaming (synced players), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->debug( 'Remote streaming iBroadcast track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{song},
		client  => $client,
	} ) || return;

	return $sock;
}

sub audioScrobblerSource { 'P' }

sub formatOverride {
	my ($class, $song) = @_;
	
	my $format = $song->pluginData( 'format' ) || 'mp3';
	
	main::DEBUGLOG && $log->is_debug && $log->debug("format override to $format");
	
	return $format;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $client = $song->master();
	my $url = $song->currentTrack()->url;
	main::DEBUGLOG && $log->is_debug && $log->debug("Getting next track url for $url");
	if (my $httpUrl = _resolveUrl($url)) {
		
		main::DEBUGLOG && $log->is_debug && $log->debug("Resolved ibcst url for next track: $httpUrl");
		$song->streamUrl($httpUrl);

		_getContentTypeHeader($httpUrl,
			sub {
				my ($contentType) = @_;
				my $format = _content_type_to_lms_format($contentType);
				
				$song->pluginData( 'format', $format );
				main::DEBUGLOG && $log->is_debug && $log->debug("Content-Type indicates format is $format");
				
				# now try to acquire the header for seeking and various details
				Slim::Utils::Scanner::Remote::parseRemoteHeader(
				$song->track, $httpUrl, $format,
				sub {
					main::DEBUGLOG && $log->is_debug && $log->debug("found $format header");					
					$client->currentPlaylistUpdateTime( Time::HiRes::time() );
					Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
					$successCb->();
				},
				sub {
					my ($self, $error) = @_;
					$log->warn( "could not find $format header $error" );
					$successCb->();
				});
				
			},
			sub {
				$log->warn("Could not get Content-Type header, defaulting to mp3");
				$successCb->();
			}
		);

	} else {		
		$log->error("$url is invalid");					
		$errorCb->();		
	}
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

sub _getContentTypeHeader {
	my ($url, $cb, $errorCb) = @_;	

	my $http = Slim::Networking::Async::HTTP->new;
	my $request = HTTP::Request->new( GET => $url );
	$http->send_request(
		{
			request     => $request,
			onHeaders => sub {	
				my $headers = shift->response->headers;
				my $contentType = $headers->header('Content-Type') || '';
				main::DEBUGLOG && $log->is_debug && $log->debug("Content-Type for $url is $contentType");
				$http->disconnect;
				$cb->($contentType);
			},
			onError => sub {
				my ( $http, $self ) = @_;
				my $res = $http->response;
				$log->error('Error status - ' . $res->status_line );
				$errorCb->();
			}
		}
	);

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

sub _content_type_to_lms_format {
    my ($content_type) = @_;
    return unless $content_type;

    # Normalise (lowercase, strip parameters)
    $content_type = lc($content_type);
    $content_type =~ s/;.*$//;

    my %map = (
        'audio/flac'             => 'flc',
        'audio/x-flac'           => 'flc',
        'audio/mpeg'             => 'mp3',
        'audio/mp3'              => 'mp3',
        'audio/mp4'              => 'aac',
        'audio/aac'              => 'aac',
        'audio/aacp'             => 'aac',
        'audio/x-aac'            => 'aac',
        'audio/ogg'              => 'ogg',
        'audio/opus'             => 'ogg',   # LMS treats opus in ogg as ogg
        'audio/wav'              => 'wav',
        'audio/x-wav'            => 'wav',
        'audio/x-ms-wma'         => 'wma',
        'audio/x-ms-wax'         => 'wma',
        'audio/x-matroska'       => 'mka',
        'audio/webm'             => 'webm',
        'audio/alac'             => 'alc',
        'audio/x-alac'           => 'alc',
    );

    # Return known format, or fall back to something generic
    return $map{$content_type} || 'mp3';
}

1;
