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

use Plugins::iBroadcast::API;

my $log   = logger('plugin.ibroadcast');
my $prefs = preferences('plugin.ibroadcast');



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
			
			my $bitrate = $track->bitrate();
			main::DEBUGLOG && $log->is_debug && $log->debug("bitrate is : $bitrate");							
			$song->bitrate($bitrate);	
			
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
