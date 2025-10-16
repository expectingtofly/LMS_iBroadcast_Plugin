package Plugins::iBroadcast::Settings;

#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.
#


use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::DateTime;

use Plugins::iBroadcast::API;

my $prefs = preferences('plugin.ibroadcast');
my $log = logger('plugin.ibroadcast');

sub name {
    return 'PLUGIN_IBROADCAST';
}

sub page {
    return 'plugins/iBroadcast/settings/basic.html';
}

sub handler {
   	my ( $class, $client, $params, $callback, @args ) = @_;

     if ( $params->{signin} ) {

		my $loginMethod = $params->{pref_loginmethod};
		Plugins::iBroadcast::API::getLoginToken(						
			$params->{pref_username},
			$params->{pref_password},			
			sub {
				my $msg ='<strong>Successfully signed in</strong>';
				my $isValid = 0;
				
				$params->{warning} .= $msg . '<br/>';
				my $body = $class->SUPER::handler( $client, $params );

				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = $isValid;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}
				
				$callback->( $client, $params, $body, @args );				
			},
			sub {
				my $msg ='<strong>There was a problem with sign in, please try again</strong>';
				$params->{warning} .= $msg . '<br/>';
				if ( $params->{AJAX} ) {
					$params->{warning} = $msg;
					$params->{validated}->{valid} = 0;
				}else {
					$params->{warning} .= $msg . '<br/>';
				}				
				my $body = $class->SUPER::handler( $client, $params );
				$callback->( $client, $params, $body, @args );
			}
		);		
		main::DEBUGLOG && $log->is_debug && $log->debug("--handler save sign in");
		return;
	} elsif ( $params->{signout} ) {
		$prefs->remove('usertoken');
		$params->{warning} .= '<strong>signed out</strong><br/>';
		Plugins::iBroadcast::API::signOut(
			sub {
				main::DEBUGLOG && $log->is_debug && $log->debug("Successfully Signed out");
			},
			sub {
				$log-warn("Sign out failed, but clearing tokens anyway....");
			}
		);		
	}
		
   	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++beforeRender");	


	if ($prefs->get('usertoken')) {
		$paramRef->{isSignedIn} = 1;
		$paramRef->{isSignedOut} = 0;		
	} else {
		$paramRef->{isSignedIn} = 0;
		$paramRef->{isSignedOut} = 1;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--beforeRender");
}


sub prefs {
	main::DEBUGLOG && $log->is_debug && $log->debug("++prefs");


	main::DEBUGLOG && $log->is_debug && $log->debug("--prefs");
	return ($prefs, qw(token bitrate));
}

1;

