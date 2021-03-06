# A description of what this class does
#
# @summary A short summary of the purpose of this class
#
# @example
#   include profile::glpi_standalone
class profile::glpi_standalone (
  Boolean $manage_firewall     = true,
  Boolean $manage_repos        = true,
  String $upstream_url         = 'glpi.lab.fail',
  Integer $port                = 80,
  String $php_fpm_url          = 'localhost:9000',
  String $www_root             = '/var/www/glpi/current',
  Boolean $tls                 = false,
  String $tls_public_key       = undef,
  String $tls_private_key      = undef,
  String $tls_path             = '/etc/nginx/certs',
  String $tls_file_owner       = 'nginx',
  String $tls_file_group       = 'nginx',
  String $mariadb_package_base = 'rh-mariadb102',
  Array $plugins               = [],
){
  if ! $facts['os']['family'] == 'RedHat' {
    fail('Only works on RHEL/CentOS for now')
  }

  contain ::nginx
  class{'::glpi':
    manage_repos => $manage_repos,
  }
  if $facts['os']['release']['major'] == '7' and $manage_repos {
    ensure_packages("${mariadb_package_base}-runtime")
    ensure_packages("${mariadb_package_base}-syspaths")
    Package["${mariadb_package_base}-syspaths"] -> Class['::mysql::server']
  }

  # very ugly workaround for a db init bug in puppetlabs-mysql
  # https://tickets.puppetlabs.com/browse/MODULES-4794
  file { '/usr/libexec/mysqld':
    ensure  => 'link',
    target  => "/opt/rh/${mariadb_package_base}/root/usr/libexec/mysqld",
    before => Class['::mysql::server'],
  }

  include ::mysql::server

  if $tls {
    file { $tls_path:
      ensure => directory,
      owner  => $tls_file_owner,
      group  => $tls_file_group,
    }
    $crt = "${tls_path}/${upstream_url}.crt"
    $key = "${tls_path}/${upstream_url}.key"
    file { $crt:
      ensure  => file,
      owner   => $tls_file_owner,
      group   => $tls_file_group,
      content => $tls_public_key,
    }
    file { $key:
      ensure  => file,
      owner   => $tls_file_owner,
      group   => $tls_file_group,
      mode    => '0600',
      content => $tls_private_key,
    }
    $server_tls_options = {
      'ssl'      => true,
      'ssl_cert' => $crt,
      'ssl_key'  => $key,
    }
    $location_tls_options = {
      'ssl' => true,
    }
  }
  else {
    $server_tls_options = {
      'ssl' => false,
    }
    $location_tls_options = {
      'ssl' => false,
    }
  }

  nginx::resource::server { $upstream_url:
    listen_port => $port,
    www_root    => $www_root,
    *           => $server_tls_options,
  }

  nginx::resource::location{ 'glpi_config':
    ensure        => present,
    server        => $upstream_url,
    www_root      => "${www_root}/config",
    location_deny => ['all'],
    *             => $location_tls_options,
  }
  nginx::resource::location{ 'glpi_files':
    ensure        => present,
    server        => $upstream_url,
    www_root      => "${www_root}/files",
    location_deny => ['all'],
    *             => $location_tls_options,
  }
  nginx::resource::location { 'glpi_root':
    ensure              => present,
    server              => $upstream_url,
    www_root            => $www_root,
    location            => '~ \.php$',
    index_files         => ['index.php'],
    proxy               => undef,
    fastcgi             => $php_fpm_url,
    fastcgi_script      => undef,
    location_cfg_append => {
      fastcgi_connect_timeout => '3m',
      fastcgi_read_timeout    => '3m',
      fastcgi_send_timeout    => '3m'
    },
    *                   => $location_tls_options,
  }

  if $manage_firewall {
    ['http','https'].each |$svc| {
      firewalld_service {"Allow access to ${svc}":
        ensure  => present,
        service => $svc,
        zone    => 'public',
      }
    }
  }

  $plugins.each |String $plugin| {
    include "::glpi::plugin::${plugin}"
  }
}
