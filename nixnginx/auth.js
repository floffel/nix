// Options. Self explaining.
var options =  {
  subrequest: {
    url: '/ldapauth',
    method: 'GET',
    argname: 'auth',
  },
  server: {
    imap: [{
      host: '10.20.20.13',
      //port: '587',
      port: '143',
      auth: ['plain', 'login'],
    }],
    pop3: [{
      host: '10.20.20.13',
      port: '110',
      auth: ['plain'],
    }],
    smtp: [{
      host: '10.20.20.13',
      port: '25',
      auth: ['none'],
    }
    /*, {
      host: '172.16.16.12',
      port: '587',
      auth: ['plain', 'login'],
    }*/
    ],
  },
  errors: {
    generic: {
      code: '500 generic',
      msg: 'Some generic internal server error occoured',
    },
    noAuthMethod: {
      code: '501 authmethod',
      msg: 'No server for the desired auth method available',
    },
    unauthorized: {
      code: '503 user',
      msg: 'Username or Password are not right',
    },
    tooFewHeaders: {
      code: '404 header',
      msg: 'One or more headers could not be found',
    },
    tooManyRetrys: {
      code: '403 retrys',
      msg: 'Too many retrys! Please try again later',
    },
    unknownProtocol: {
      code: '403 protocol',
      msg: 'Protocol not known. Please use imap/smtp/pop3',
    },
    noAuth: {
      code: '401 auth',
      msg: 'No authorization possible',
    },
  },
  retrys: 10,
}

// helper function, to gather all arguments, i.e. headers from a request
// and checks them for existenis/emptyness
function isHeaderNan() {
  var args = Object.values(arguments);

  for(var i=0; i<args.length; i++) { 
    if(!args[i] || args[i] === '') {
      return true;
    }
  }

  return false;
}


function printHeaders(r) {
  r.status = 200;
  r.headersOut['Content-Type'] = "text/plain; charset=utf-8";
  var out = "";

// see https://github.com/nginx/njs/issues/192#issuecomment-509598730
  for (var h in r.headersIn) {
    var key = h;
    var val = r.headersIn[h];
    r.headersOut[key] = val;
    out += key + ": " + val + "<br>";
  }

  r.headersOut['Content-Length'] = out.length;
  r.headersOut['Auth-Error-Code'] = 42;
  r.headersOut['Auth-Status'] = out;
  r.sendHeader();
  r.send(out);
  r.finish();
}


// helper method for getting a single server, which is
// applicable for serving the desired auth method
function getServer(s, m) {


  //return(s[0]);

  var ms = 0;

  var servers = [];
  for(var i in s) {
    if(s[i].auth.includes(m)) {
      servers.push(s[i]);
    }
  }

  if(servers.length == 0) {
    return false;
  }

  var rnd = Math.floor(Math.random() * servers.length);
  return servers[rnd];


  for(var i in s) {
    if(s[i].auth.includes(m)) {
      ms++;
    }
  }

  if(ms == 0) {
    return false;
  }

  var rnd = Math.floor(Math.random() * ms);


  // check if the server arry includes one that supports the method
  for(var i in s) {
    if(s[i].auth.includes(m)) {
      rnd--;
    }
    if(rnd <= 0) {
      return s[i];
    }
  }
}

// helper function to design the good respnse, see:
// http://nginx.org/en/docs/mail/ngx_mail_auth_http_module.html#protocol
function success(r, s) {
  r.status = 200;
  r.headersOut['Auth-Status'] = 'OK';
  r.headersOut['Auth-Server'] = s.host;
  r.headersOut['Auth-Port'] = s.port;
  r.sendHeader();
  r.finish();
}

// helper function to design the bad response, see:
// http://nginx.org/en/docs/mail/ngx_mail_auth_http_module.html#protocol
function failure(r, a, e) {
  // r.error("NjsLdapAuth: " + e.code + e.msg);
  r.status = 200;
  r.headersOut['Auth-Error-Code'] = e.code;
  r.headersOut['Auth-Status'] = e.msg;
  if(a.attempt < options.retrys) { 
    r.headersOut['Auth-Wait'] = options.retrys + a.attempt + 30;
  } else {
    r.headersOut['Auth-Wait'] = 999;
  }
  r.sendHeader();
  r.send(e.msg);
  r.finish();
}

// validate function - a njs_content (action) to be called inside the location directive
// this function does the "validating (directing to ldap_auth)" 
function validate(r) {



  var auth = {
    method: r.headersIn['Auth-Method'],
    user: r.headersIn['Auth-User'],
    pass: r.headersIn['Auth-Pass'],
    protocol: r.headersIn['Auth-Protocol'],
    attempt: r.headersIn['Auth-Login-Attempt'],
    clientip: r.headersIn['Client-IP'],
  }
  // obsolete: clienthost: r.headersIn['Client-Host'],
  //
  //
  

  r.error("getting server for: " + auth.method);

 	// TODO: this is a temporary fix. We do not auth anything!! remove the next lines for real auth...
        var server = getServer(options.server[auth.protocol], auth.method);
	//var server = options.server[auth.protocol][0];
	
  r.error("got server " + server.host + " : " + server.port);

        if(!server) {
          failure(r, auth, options.errors.generic)
        } else {
          success(r, server);
        }
 	return;
 	// TODO end...

  if(auth.attempt >= options.retrys) {
    failure(r, auth, options.errors.tooManyRetrys);
    return;
  }

  if(auth.method == 'none') {
    if(isHeaderNan(auth.method, auth.protocol, auth.attempt, auth.clientip)) {
      failure(r, auth, options.errors.tooFewHeaders);
      return;
    }

    var server = getServer(options.server[auth.protocol], auth.method);
    if(!server) {
      failure(r, auth, options.errors.generic)
    } else {
      success(r, server);
    }
    return;
  }

  if(isHeaderNan(auth.method, auth.user, auth.pass, auth.protocol, auth.attempt, auth.clientip)) {
    //dbg: printHeaders(r);
    failure(r, auth, options.errors.tooFewHeaders);
    return;
  }

  try { // fix ambougius bug where toUTF8() is no method on intermediate value... todo: needs some further investigation 
    var authstring = ( auth.user + ':' + auth.pass ).toUTF8().toString('base64'); 
  } catch(error) {
    failure(r, auth, options.errors.generic);
    return;
  }

  r.subrequest(options.subrequest.url, { body: '', args: (options.subrequest.argname + '=' + authstring), method: options.subrequest.method }, function(c) {
    switch(c.status) {
      case 200:
        var server = getServer(options.server[auth.protocol], auth.method);
        if(!server) {
          failure(r, auth, options.errors.generic)
        } else {
          success(r, server);
        }
        break;
      case 401:
        failure(r, auth, options.errors.noAuth);
        break;
      case 503:
        failure(r, auth, options.errors.unauthorized);
        break;
      default:
        failure(r, auth, options.errors.generic);
        break;
    }
  });
}

// main purpose is to replay status code 200
// to be send when a ldap request suceeds
// to be used inside a nginx location directive
function granted(r) {
  r.status = 200;
  r.headersOut['Content-Type'] = "text/plain; charset=utf-8";
  r.headersOut['Content-Length'] = 3;
  r.sendHeader();
  r.send('ack');
  r.finish()
}

export default { printHeaders, validate, granted };
