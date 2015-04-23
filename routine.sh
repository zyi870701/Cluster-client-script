#!/bin/bash

# routine jobs ... use crontab to execute

# check if it is already executing...

# -------------------------------------------------------
# setup home_local directory and quota for ldap users
dir_r=/home_local/

set -x
quotacheck -avug
quotaon -auvg

users=`ldapsearch -x | grep "dn.*uid=.*,cn=users" |cut -f 2 -d '=' |cut -f 1 -d ','`

for user in $users
do
   if [ ! -d $dir_r/$user ]; then
      mkdir -p $dir_r/$user
      chown $user:users $dir_r/$user
   fi
   edquota -p speech -u $user
done
# -------------------------------------------------------


# -------------------------------------------------------
# copy corpus from NAS...
for file in /corpus_tar/*
do
   unzip_file=$(tar -tf $file 2>/dev/null |head -n 1)
   [ -z "$unzip_file" ] && continue;
   [ ! -e  /corpus/$unzip_file ] && tar zxvf $file -C /corpus

   chmod 755 $(find /corpus/$unzip_file -type d)
   chmod 644 $(find /corpus/$unzip_file -type f)
done
# -------------------------------------------------------

