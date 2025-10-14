package Plugins::iBroadcast::API;

use warnings;
use strict;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use POSIX qw(strftime);  

use Slim::Networking::SimpleSyncHTTP;

use JSON::XS::VersionOneAndTwo;

use Data::Dumper;

my $prefs = preferences('plugin.ibroadcast');
my $log = logger('plugin.ibroadcast');

use constant API_URL => 'https://api.ibroadcast.com/s/JSON/';
use constant API_LIBRARY_URL => 'https://library.ibroadcast.com/';
use constant APP_ID => '1200';


sub getLoginToken {
    my ($logintoken, $appID, $cbY, $cbN) = @_;

    main::DEBUGLOG && $log->is_debug && $log->debug('logging in');
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
       	sub {
			my $http = shift;
            my $JSON = decode_json ${ $http->contentRef };

            if ( $JSON->{result}) {
                main::DEBUGLOG && $log->is_debug && $log->debug('logged in');
                $prefs->set('usertoken', $JSON->{user}->{token});
                $prefs->set('userid', $JSON->{user}->{id});
                $cbY->();
                return;
            } else {
                main::DEBUGLOG && $log->is_debug && $log->debug('login failed');
                $cbN->();
                return;
            }
          #result
        },
        sub {
            $log->warn("error getting login token: $_[1]");
            $cbN->();
        }
    );
    
    my $post = to_json({
        mode => 'login_token',
        client => 'LMS_iBroadcast_Plugin',
        app_id => $appID || APP_ID,
        type => 'account',
        device_name => 'LMS',
        login_token => $logintoken,
    } );

    main::DEBUGLOG && $log->is_debug && $log->debug('sending ' .$post);

    $http->post(
		API_URL.'login_token',
		'Content-Type' => 'application/json',
		$post,
	);


    return;
}

sub signOut {
    my ($cbY, $cbN) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug('Sign out');

    my $post = to_json(addAuth({
        mode => 'logout',
    }));

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $JSON = decode_json ${ $http->contentRef };

            if ( $JSON->{result}) {
                
                main::DEBUGLOG && $log->is_debug && $log->debug('library status retrieved');
                $cbY->($JSON);
                return;
            } else {
                main::DEBUGLOG && $log->is_debug && $log->debug('failed to retrieve library status');
                $cbN->();
                return;
            }
        },
        sub {
            $log->error("Error signing out: $_[1]");
            $cbN->();
        }
    );

    $http->post(
        API_URL.'logout',
        'Content-Type' => 'application/json',
        $post,
    );

    return;
}
        
    
sub getLibraryStatus {
    my ($cbY, $cbN) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug('getting library status');
    
    my $post = to_json(addAuth({
        mode => 'status',
    }));
        
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $JSON = decode_json ${ $http->contentRef };

            if ( $JSON->{authenticated}) {
                if ( $JSON->{result}) {                
                    main::DEBUGLOG && $log->is_debug && $log->debug('library status retrieved');
                    $cbY->($JSON);
                    return;
                } else {
                    main::DEBUGLOG && $log->is_debug && $log->debug('failed to retrieve library status');
                    $cbN->();
                    return;
                }
            } else {
                Plugins::iBroadcast::API::checkAuthenticated($JSON,
                    sub {
                        main::DEBUGLOG && $log->is_debug && $log->debug('failed to retrieve library status due to authentication, but now authenticated');
                        $cbN->();
                    },
                    sub {
                      $log->warn('Failed to get library status due to authentication issues');
                       $cbN->();
                    });
            }            
        },
        sub {
            $log->error("error getting library status: $_[1]");
            $cbN->();
        }
    );

    $http->post(
        API_URL.'status',
        'Content-Type' => 'application/json',
        $post,
    );

    return;
}

sub getLibrarySync {    
    my ($cbY, $cbN, $retry) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug('getting library');    
    
    my $post = to_json(addAuth({
        mode => 'library',
    }));
        
    
    my $result = Slim::Networking::SimpleSyncHTTP->new()->post(                  
        API_LIBRARY_URL.'library',
        'Content-Type' => 'application/json',
        $post,
    );
    if ( $result->is_success ) {        
       my $JSON = decode_json ${ $result->contentRef };       
       return $JSON;
    } else {
         $log->error("Error getting library");
         return;
    }

}

sub addAuth {
    my ($data) = @_; 
    $data->{user_id} = $prefs->get('userid') if $prefs->get('usertoken');
    $data->{client} = 'LMS_iBroadcast_Plugin';
    $data->{device_name} = 'LMS';
    $data->{token} = $prefs->get('usertoken')  if $prefs->get('usertoken');
    return $data;
}

sub statusHistoryRecord {
     my ($track, $TIMESTAMP, $cbY, $cbN) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug('Record the playing status');

    my $history  = {
        "history" => [ {
            "day"      => strftime("%Y-%m-%d", localtime($TIMESTAMP)),
            "plays"   =>  {
                $track => 1
            },
            "detail" =>  {                
                $track => [
                    {
                        event => 'play',
                        "ts"  => strftime("%Y-%m-%d %H:%M:%S", localtime($TIMESTAMP)),
                    }
                ]
            }
        }]    
    };
    
    my $post = to_json(addAuth({
        mode => 'status',
        history => $history->{history},
    }));
        
    main::DEBUGLOG && $log->is_debug && $log->debug('sending ' .$post);

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $JSON = decode_json ${ $http->contentRef };

            if ( $JSON->{result}) {
                main::DEBUGLOG && $log->is_debug && $log->debug('library status retrieved with history');
                $cbY->($JSON);
                return;
            } else {
                main::DEBUGLOG && $log->is_debug && $log->debug('failed to retrieve library status');
                $cbN->();
                return;
            }
        },
        sub {            
            $log->error("error recording play history: $_[1]");
            $cbN->();
        }
    );

    $http->post(
        API_URL.'status',
        'Content-Type' => 'application/json',
        $post,
    );

    return;

}

sub getUserStatus {
     my ($cbY, $cbN) = @_;
    main::DEBUGLOG && $log->is_debug && $log->debug('Get User Status');

    my $post = to_json(addAuth({
        mode => 'status',
    }));

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $JSON = decode_json ${ $http->contentRef };
            main::DEBUGLOG && $log->is_debug && $log->debug('Get User Status');
            main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($JSON));            
            $cbY->($JSON);
            return;
           
        },
        sub {
            $log->error("Error Getting Status: $_[1]");
            $cbN->();
        }
    );

    $http->post(
        API_URL.'status',
        'Content-Type' => 'application/json',
        $post,
    );

    return;
}


1;