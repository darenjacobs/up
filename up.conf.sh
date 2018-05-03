#
# This file is managed by Salt (source: devenv.up.cli) - local changes will be overwritten on update.
#

SALT_CLOUD_DOMAIN={{ salt['ktpillar.get']('salt:cloud:domain') }}
SALT_CLOUD_SUBDOMAIN={{ salt['ktpillar.get']('salt:cloud:subdomain') }}
SALT_CLOUD_TIMEOUT={{ salt['ktpillar.get']('salt:cloud:timeout') }}
SALT_CLOUD_SIZES=({{ salt['ktpillar.get']('salt:cloud:providers:softlayer:profiles').keys() | join(' ')  }})
SALT_CLOUD_DEFAULT_SIZE={{ salt['ktpillar.get']('salt:cloud:default_size') }}
SALT_CLOUD_PROVIDERS=({{ salt['ktpillar.get']('salt:cloud:providers').keys() | join(' ')  }})
SALT_CLOUD_DEFAULT_PROVIDER={{ salt['ktpillar.get']('salt:cloud:default_provider') }}
SALT_CLOUD_LIFESPANS=({{ salt['ktpillar.get']('salt:cloud:lifespans').keys() | join(' ') }})
SALT_CLOUD_DEFAULT_LIFESPAN={{ salt['ktpillar.get']('salt:cloud:default_lifespan') }}
SALT_CLOUD_DEDICATED={{ salt['ktpillar.get']('salt:cloud:providers:softlayer:dedicated')  }}

DEVENV_VERSION={{ salt['ktpillar.get']('versions:devenv') }}
DEVENV_MASTER={{ salt['ktpillar.get']('devenv:master') }}
