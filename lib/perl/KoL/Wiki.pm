# $Id$

# Wiki.pm
#   Class for reading Wiki pages.

package KoL::Wiki;

use strict;
use LWP;
use LWP::UserAgent;
use URI::Escape;
use KoL;
use KoL::Logging;

my (%_cachedResults);

sub new {
    my $class = shift;
    my %args = @_;
    my $kol = KoL->new();
    
    # Defaults.
    if (!exists($args{'agent'})) {
        $args{'agent'} = !exists($args{'session'}) ? 'KoLAPI/' . $kol->version() :
                            $args{'session'}->{'agent'};
    }
    if (!exists($args{'timeout'})) {
        $args{'timeout'} = !exists($args{'session'}) ? 60 :
                            $args{'session'}->{'timeout'};
    }
    if (!exists($args{'server'})) {
        $args{'server'} = 'kol.coldfront.net';
    }
    
    if (!exists($args{'email'})) {
        if (exists($args{'session'})) {
            $args{'email'} = $args{'session'}->{'email'};
        } else {
            $@ = "You must supply an email address.";
            return(undef);
        }
    }
    
    my $self = {
        'agent'         => $args{'agent'},
        'timeout'       => $args{'timeout'},
        'email'         => $args{'email'},
        'server'        => $args{'server'},
        'lwp'           => undef,
        'log'           => KoL::Logging->new(),
        'no_dos'        => {
            'second'    => 0,
            'count'     => 0,
        }
    };
    
    bless($self, $class);
    
    $self->{'log'}->debug("Configuring LWP with '" . $self->{'agent'} . 
                "' and a timeout of " . $self->{'timeout'} . " seconds.");
    $self->{'lwp'} = LWP::UserAgent->new(
        'agent'                 => $self->{'agent'},
        'from'                  => $self->{'email'},
        'cookie_jar'            => {},
        'requests_redirectable' => ['HEAD', 'GET', 'POST'],
        'timeout'               => $self->{'timeout'},
    );
    
    return($self);
}

sub getPage {
    my $self = shift;
    my $name = shift;
    $name =~ s/\s/_/g;
    
    # Check the cache
    if (!exists($_cachedResults{$name}) ||
        time() - $_cachedResults{$name}{'cached'} > 3600) {
        $self->{'log'}->msg("Searching Wiki for '$name'", 10);
        
        my $resp = $self->get("thekolwiki/index.php/$name");
        return(undef) if (!$resp);
        
        # Pull the content out of the page.
        if ($resp->content() !~ m/<!-- start content -->(.+?)<!-- end content -->/s) {
            $self->logResponse("Unable to find content", $resp);
            $@ = "Unable to find content!";
            return(undef);
        }
        my $content = $1;
        
        if ($content !~ m/>Item number.*?:.*? (\d+)/ &&
            $content !~ m/>Effect number.*?:.*? (\d+)/) {
            $self->{'log'}->msg("Page does not appear to be for an effect or item:\n" .
                                $content, 30);
            $@ = "Page does not appear to be for an effect or item!";
            return(undef);
        }
        my $id = $1;
        
        if ($content !~ m/>Description ID.*?:.+?> (.+?)</) {
            $self->{'log'}->msg("Unable to locate description id:\n" .
                                $content, 30);
            $@ = "Unable to locate description id!";
            return(undef);
        }
        my $desc = $1;
        
        $_cachedResults{$name} = {'id' => $id, 'desc' => $desc, 'cached' => time()};
    }
    
    if (exists($_cachedResults{$name})) {
        my %info = %{$_cachedResults{$name}};
        delete($info{'cached'});
        return(\%info);
    }
    
    $@ = "Unable to location '$name'.";
    return(undef);
}

sub _processResponse {
    my $self = shift;
    my $resp = shift;
    
    # Simple record keeping to cut down on DoS like usage.
    if ($self->{'no_dos'}{'second'} != time()) {
        $self->{'no_dos'}{'second'} = time();
        $self->{'no_dos'}{'count'} = 0
    }
    $self->{'no_dos'}{'count'}++;
    
    # HTTP failure
    if (!$resp->is_success()) {
        $@ = $resp->status_line;
        return(undef);
    }
    
    # Anything special we should be processing here?
        
    return($resp);
}

sub request {
    my $self = shift;
    my $type = shift;
    my $uri = shift;
    my $form = shift;
    my $headers = shift;
    
    $type = lc($type);
    if (!grep(/^\Q$type\E$/, ('get', 'head', 'post'))) {
        $@ = "Unknown request type '$type'!";
        return(0);
    }
    
    # Figure out form data and method args.
    my (@args);
    if ($type eq 'post') {
        push(@args, $form) if ($form);
        push(@args, $headers) if ($headers);
    } elsif ($type =~ m/get|head/ && ref($form) eq 'HASH') {
        my (@qry);
        foreach my $opt (keys(%{$form})) {
            my $key = URI::Escape::uri_escape($opt);
            my $val = URI::Escape::uri_escape($form->{$opt});
            push(@qry, "$key=$val");
        }
        $uri .= '?' . join('&', @qry);
        push(@args, $headers) if ($headers);
    }
    
    # Place nice and try not to DoS KoL.
    sleep(1) if (time() - $self->{'no_dos'}{'second'} < 1 &&
                    $self->{'no_dos'}{'count'} >= 30);
    
    my $url = 'http://' . $self->{'server'} . "/$uri";
    $self->{'log'}->msg("'$type' request for '$url'.", 10);
    return($self->_processResponse($self->{'lwp'}->$type($url, @args)));
}

sub get {
    my $self = shift;
    return($self->request('get', @_));
}

sub post {
    my $self = shift;
    return($self->request('post', @_));
}

sub head {
    my $self = shift;
    return($self->request('head', @_));
}

sub logResponse {
    my $self = shift;
    my $msg = shift;
    my $resp = shift;
    my $level = shift || 30;
    
    $self->{'log'}->msg("$msg:\n" .
                        "Status Line: " .  $resp->status_line() .
                        "\nHeaders:\n" . $resp->headers()->as_string() .
                        "\nCookie:\n" . $self->{'lwp'}->cookie_jar()->as_string() .
                        "\nContent:\n" . $resp->content(), $level);
}

1;