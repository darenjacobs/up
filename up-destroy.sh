#!/bin/sh

DESTROY_LOG=/var/log/upsight/up_destroy.log

set -o pipefail

hour="$(date +'%H')"
today="$(date +'%s')"
day_of_week="$(date +'%w')"
tomorrow="$((today + 86400))"
vars=( create_ts lifespan owner prefix )
tmp_file=$(mktemp)

salt-call upsight_devenv.list pretty=True >${tmp_file} 2>/dev/null

# check if current time is between Monday noon and Friday
if [ "$day_of_week" -ge 2 ] && [ "$day_of_week" -le 5 ] || [[ "$day_of_week" -eq 1 && "$hour" -ge 19 ]]; then
  DETONATE="true"
fi

for file in $(ls /etc/salt/cloud.maps.d/*.map); do
    for i in "${vars[@]}"; do
        declare $i=$(grep "^# $i:" $file | cut -f 3 -d' ')
    done

    # Check if the VM is running
    formatted_owner="$(echo -e ${owner} | sed -e 's/\./-/g')"
    is_running=$(grep ${prefix}.${formatted_owner} ${tmp_file})

    if [ ! -z "$is_running" ] && [ ! -z "$create_ts" ]; then
        # Today check
        expiration=$(($create_ts + $lifespan))
        if [ $today -gt $expiration ]; then
            # Destroy VM
            if [[ "${DETONATE}" == "true" ]]; then
                echo "$(date): Destroying VM for map file $file now. Expiration: $(date -d @$expiration)" | tee -a $DETROY_LOG
                salt-run state.orchestrate orch.devenv.destroy pillar="{\"devenv_owner\":\"${owner}\",\"devenv_prefix\":\"${prefix}\"}" &>> $DESTROY_LOG
            fi
        fi

        # Tomorrow check
        if [ $tomorrow -gt $expiration ]; then
            #Write to log
            secs="$((expiration - today))"
            destroy_time=$(printf '%d hour(s) %d minutes\n' $(($secs/3600)) $(($secs%3600/60)))
            echo -e "$(date): VM for map file: $file will be destroyed in ${destroy_time}. Expires: $(date -d @$expiration)" | tee -a $DESTROY_LOG

            #Email user
            if [[ "${DETONATE}" == "true" ]]; then
              DESTROY_TIME="in ${destroy_time}."
            else
              DESTROY_TIME="on Monday at noon."
            fi
            MESSAGE="Greetings $owner, \n\nYour VM: $prefix will be destroyed ${DESTROY_TIME}\n\nRun \"up destroy ${prefix}\" to manually terminate this VM and stop these reminders.\n\nHave a nice day!"
            SUBJECT="Your VM: $prefix is about to expire."
            FROM="DevOps <devops@upsight.com>"
            email="${owner}@upsight.com"
            echo -e $MESSAGE | /bin/mail -s "$SUBJECT" -r "$FROM" "$email"
        fi
    fi
done

# Remove temp file
rm $tmp_file
