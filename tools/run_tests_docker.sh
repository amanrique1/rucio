#!/bin/bash
# Copyright 2017-2020 CERN for the benefit of the ATLAS collaboration.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Authors:
# - Thomas Beermann <thomas.beermann@cern.ch>, 2017-2018
# - Vincent Garonne <vincent.garonne@cern.ch>, 2018
# - Hannes Hansen <hannes.jakob.hansen@cern.ch>, 2018-2019
# - Mario Lassnig <mario.lassnig@cern.ch>, 2019
# - Martin Barisits <martin.barisits@cern.ch>, 2019
# - Andrew Lister <andrew.lister@stfc.ac.uk>, 2019
# - Patrick Austin <patrick.austin@stfc.ac.uk>, 2020
# - Cedric Serfon <cedric.serfon@cern.ch>, 2020
# - Eli Chadwick <eli.chadwick@stfc.ac.uk>, 2020
# - Benedikt Ziemons <benedikt.ziemons@cern.ch>, 2020

memcached -u root -d

function usage {
  echo "Usage: $0 [OPTION]..."
  echo 'Run Rucio test suite'
  echo ''
  echo '  -h    Show usage.'
  echo '  -i    Do only the initialization.'
  echo '  -r    Activate default RSEs (XRD1, XRD2, XRD3)'
  echo '  -s    Run special tests for Dirac. Includes using BelleII schema'
  exit
}

while getopts hirs opt
do
  case "$opt" in
    h) usage;;
    i) init_only="true";;
    r) activate_rse="true";;
    s) special="true";;
  esac
done
export RUCIO_HOME=/opt/etc/test

echo 'Clearing memcache'
echo flush_all > /dev/tcp/127.0.0.1/11211

echo 'Graceful restart of Apache'
httpd -k graceful

echo 'Cleaning old authentication tokens'
rm -rf /tmp/.rucio_*/

echo 'Cleaning local RSE directories'
rm -rf /tmp/rucio_rse/*

echo 'Removing old SQLite databases'
rm -f /tmp/rucio.db

if test ${special}; then
    if [ -f /opt/rucio/etc/rucio.cfg ]; then
        echo 'Remove rucio.cfg'
        rm /opt/rucio/etc/rucio.cfg
    fi
    echo 'Using the special config'
    ln -s /opt/rucio/etc/rucio.cfg.special /opt/rucio/etc/rucio.cfg
else
    if [ -f /opt/rucio/etc/rucio.cfg ]; then
        echo 'Using the standard conig'
    else
        echo 'rucio.cfg not found. Will try to do a symlink'
        ln -s /opt/rucio/etc/rucio.cfg.default /opt/rucio/etc/rucio.cfg
    fi
fi

echo 'Resetting database tables'
tools/reset_database.py
if [ $? != 0 ]; then
    echo 'Failed to reset the database!'
    exit 1
fi

if [ -f /tmp/rucio.db ]; then
    echo 'Disable SQLite database access restriction'
    chmod 777 /tmp/rucio.db
fi

echo 'Running full alembic migration'
alembic -c /opt/rucio/etc/alembic.ini downgrade base
if [ $? != 0 ]; then
    echo 'Failed to downgrade the database!'
    exit 1
fi
alembic -c /opt/rucio/etc/alembic.ini upgrade head
if [ $? != 0 ]; then
    echo 'Failed to upgrade the database!'
    exit 1
fi

echo 'Bootstrap tests: Create jdoe account/mock scope'
tools/bootstrap_tests.py
if [ $? != 0 ]; then
    echo 'Failed to bootstrap!'
    exit 1
fi

echo 'Sync rse_repository'
if test ${special};then
    tools/sync_rses.py etc/rse_repository.json.special
    if [ $? != 0 ]; then
        echo 'Failed to sync!'
        exit 1
    fi
else
    tools/sync_rses.py
    if [ $? != 0 ]; then
        echo 'Failed to sync!'
        exit 1
    fi
fi

echo 'Sync metadata keys'
tools/sync_meta.py
if [ $? != 0 ]; then
    echo 'Failed to sync!'
    exit 1
fi

echo 'Bootstrap tests: Create jdoe account/mock scope'
tools/bootstrap_tests.py
if [ $? != 0 ]; then
    echo 'Failed to bootstrap!'
    exit 1
fi

if test ${activate_rse}; then
    echo 'Activating default RSEs (XRD1, XRD2, XRD3)'
    tools/docker_activate_rses.sh
fi


if test ${init_only}; then
    exit
fi

TESTS="lib/rucio/tests/test_"
if test ${special}; then
    echo 'Using the special config'
    pytest -v --full-trace ${TESTS}dirac.py
else
    echo 'Running tests'
    pytestignores="--ignore=${TESTS}alembic.py --ignore-glob=${TESTS}rse_protocol_*.py --ignore=${TESTS}rucio_server.py --ignore-glob=${TESTS}auditor*.py --ignore=${TESTS}dirac.py --ignore=${TESTS}multi_vo.py"
    pytest -v --full-trace $pytestignores
fi

exit $?
