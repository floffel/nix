<?php
class sieve_master extends rcube_plugin
{
    public $task = 'settings';

    function init()
    {
        $this->add_hook('managesieve_connect', [$this, 'managesieve_connect']);
    }

    function managesieve_connect($args)
    {
        // Roundcube's core OAuth hook overwrites auth_type with XOAUTH2 for
        // IMAP/SMTP. That is invalid for ManageSieve here. Force the Dovecot
        // master PLAIN credentials read from the shared secrets mount.
        unset($_SESSION['oauth_token']['auth_type']);
        $args['auth_type'] = 'PLAIN';
        $args['auth_cid'] = 'sieveadmin';
        $args['auth_pw'] = trim(@file_get_contents('/var/lib/secrets/ssl/minnecker.com/managesieve-master-password'));
        return $args;
    }
}
