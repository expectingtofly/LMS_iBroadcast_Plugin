package Plugins::iBroadcast::Plugin;

#  (c) stu@expectingtofly.co.uk  2025
#
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


use warnings;
use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::iBroadcast::Importer;
use Plugins::iBroadcast::ProtocolHandler;
use Plugins::iBroadcast::API;


use Data::Dumper;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.ibroadcast',
		'defaultLevel' => 'WARN',
		'description'  => getDisplayName(),
	}
);

my $prefs = preferences('plugin.ibroadcast');





sub initPlugin {
	my $class = shift;

	$prefs->init(
		{
			bitrate => '128', 
		}
	);

		
	$class->SUPER::initPlugin();

	if ( !$::noweb ) {

		require Plugins::iBroadcast::Settings;
		Plugins::iBroadcast::Settings->new;
	}


	# tell LMS that we need to run the external scanner
	Slim::Music::Import->addImporter('Plugins::iBroadcast::Importer', { use => 1 });

	Slim::Player::ProtocolHandlers->registerHandler('ibcst', 'Plugins::iBroadcast::ProtocolHandler');
	Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('ibcst', '/plugins/iBroadcast/html/images/iBroadcastIcon.png');


	return;
}

sub postinitPlugin {
	my $class = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('postinitPlugin() called');
	
	#Check Authentication

	if ( $prefs->get('usertoken') ){
		Plugins::iBroadcast::API::getUserStatus(
			sub {
				my $JSON = shift;
				if (checkAuthenticated($JSON) ) {
					 main::DEBUGLOG && $log->is_debug && $log->debug('authenticated');
				} else {
					$log-warn ('Not authenticated');
				}
			},
			sub {
				$log->warn('Failed to get user status');
			}
		);
	}
}

sub getDisplayName { return 'PLUGIN_IBROADCAST'; }

sub onlineLibraryNeedsUpdate {
	
	my $class = shift;	
	return Plugins::iBroadcast::Importer->needsUpdate(@_);
	
	my $cb = $_[1];
	$cb->() if $cb && ref $cb && ref $cb eq 'CODE';
}

sub getLibraryStats { 	
	my $totals = Plugins::iBroadcast::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_IBROADCAST_NAME', $totals) : $totals;
}

sub checkAuthenticated {
	my $JSON = shift;
	my $cbY = shift;
	my $cbN = shift;
	
	if ($JSON->{authenticated}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('authenticated');
		return 1;
	} else {
		$log->error('Not Authenticated, Please sign in on the settings page');
		if ( $JSON->{authenticated} == 0 ) {# we got a positive not authenticated.  Remove token.
			$prefs->remove('usertoken');
		}
		return;		
	}
}


1;
