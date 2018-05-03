#!/bin/sh

set -o pipefail

# Get up.sh configuration file
if [[ -f /opt/localconfig/devenv/up.conf.sh ]]; then
   . /opt/localconfig/devenv/up.conf.sh
else
   echo "ERROR: Configuration file /opt/localconfig/devenv/up.conf.sh was not found. Aborting."
   exit 1
fi

# Set VM create default values
devenv_allowed_providers=(${SALT_CLOUD_PROVIDERS[@]})
devenv_provider=${SALT_CLOUD_DEFAULT_PROVIDER:-softlayer}
devenv_max_nodes=${DEVENV_MAX_NODES:-6}
devenv_nodes=0
devenv_owner=${SALTAPI_USER}
devenv_allowed_sizes=(${SALT_CLOUD_SIZES[@]})
devenv_size=${SALT_CLOUD_DEFAULT_SIZE:-medium}
devenv_node_size=${SALT_CLOUD_DEFAULT_SIZE:-medium}
devenv_allowed_lifespans=(${SALT_CLOUD_LIFESPANS[@]})
devenv_lifespan=${SALT_CLOUD_DEFAULT_LIFESPAN:-1week}
devenv_timeout=${SALT_CLOUD_TIMEOUT:-1800}
devenv_version=${DEVENV_VERSION}
devenv_master=${DEVENV_MASTER}
devenv_branch="develop"
devenv_master_grains=""
devenv_nodes_grains=""
devenv_master_minion=""
devenv_nodes_minion=""
devenv_pepper_args="--timeout=${devenv_timeout}"
if [[ -z $SALTAPI_PASS ]]; then
   devenv_pepper_args="$devenv_pepper_args --make-token"
fi

formatted_owner="$(echo -e ${SALTAPI_USER} | sed -e 's/\./-/g')"

if [[ $(hostname) != *sjc4* ]] && [[ $(hostname) != *sea1* ]]; then
   echo "================================================================================"
   echo "                                WARNING                                         "
   echo ""
   echo " To use the \"up\" command SSH to \"eng21\" server by running \"ssh eng21\" then run  "
   echo " \"$0 $*\" from there."
   echo "================================================================================"
   exit 1
fi

func_help(){
   echo "up version ${devenv_version}"
   echo "Property of Upsight, Inc. © 2017 501 Folsom St. San Francisco, CA 94105"
   echo ""
   echo "Contributions are welcomed at: https://stash.eng.upsight.com/projects/DEVOPS/repos/devenv/browse"
   echo ""
   echo "Create or interact with a single VM or cluster of VMs."
   echo " "
   echo "Usage: "
   echo " $0 create [--prefix <vm prefix>] [--provider <vm provider>] [-n, --nodes <number of nodes>] [-s, --size <size>] [-l, --lifespan <lifespan>] [-b, --branch <branch name>] [-G, --master_grains '<grain:value>'] [-g, --nodes_grains '<grain:value>'] [-M, --master_minion '<config:value>'] [-m, --nodes_minion '<config:value>']"
   echo "    [options]         -n, --nodes <number of nodes> (Optional. Default: ${devenv_nodes})"
   echo "                      -s, --size <vm size> (Optional. Default: ${devenv_size})"
   echo "                      -l, --lifespan <vm lifespan> (Optional. Options are ${devenv_allowed_lifespans[@]}. Default: ${devenv_lifespan})"
   echo "                      --provider <vm provider> (Optional. Options are ${devenv_allowed_providers[@]}. Default: ${devenv_provider})"
   echo "                      -b, --branch <name of DEVOPS/configuration branch> (Optional. Default: ${devenv_branch})"
   echo "                      -G, --master_grains '<grain:value>'. Set grains for master VM. (environment, location and owner grains are hardcoded)"
   echo "                          Example with multiple grains: -G '\"foo\":\"bar\"' -G '\"roles\":[\"role1\",\"role2\",\"role3\"]' -G ..."
   echo "                          NOTE: All grains need to be between single quotes"
   echo "                      -g, --nodes_grains '<grain:value>'. Set grains for all minion nodes. (environment, location and owner grains are hardcoded)"
   echo "                          Example with multiple grains: -g '\"foo\":\"bar\"' -g '\"roles\":[\"role1\",\"role2\",\"role3\"]' -g ..."
   echo "                          NOTE: All grains need to be between single quotes"
   echo "                      -M, --master_minion '<config:value>'. Set minion config for master VM. (Optional. Default: log_level: info)"
   echo "                          Example with multiple configs: -M '\"foo\":\"bar\"' -M '\"baz\":\"qux\"' -M ..."
   echo "                          NOTE: All configs need to be between single quotes"
   echo "                      -m, --nodes_minion '<config:value>'. Set minion config for minion nodes. (Optional. Default: log_level: info)"
   echo "                          Example with multiple configs: -m '\"foo\":\"bar\"' -m '\"baz\":\"qux\"' -m ..."
   echo "                          NOTE: All configs need to be between single quotes"
   echo " "
   echo " $0 destroy [-y, --yes] <vm prefix>"
   echo " $0 list [-a, --all] [-p, --showpass]"
   echo " $0 ssh <vm prefix> [owner.name]"
   echo " $0 grant <firstname.lastname> <vm prefix>"
   echo " "
   echo "ARGUMENT SUMMARY:"
   echo "-h, --help, -v, --version  shows usage and help"
   echo ""
   echo "create    create vm cluster with the provided prefix, number of nodes, and node size ex: create --prefix test --nodes 2 --size small"
   echo "          will create a cluster with one small salt master vm and 2 small minion nodes vms."
   echo "destroy   destroy master vm (single cluster) or entire cluster with the provided prefix, ex: destroy test"
   echo "ssh       ssh to the master vm with the provided prefix, ex: ssh test"
   echo "list      list your VMs, -a lists all VMs, -p shows the root password for your VMs"
   echo "grant     grant access to VMs with <vm prefix> to <user.name>, ex: grant john.doe test"
   echo ""
}

func_set_args(){
   first_arg="$1"
   second_arg="$2"
   case $first_arg in
       --prefix|-p)
           # Format prefix
           test_prefix=$second_arg
           if [[ -z ${test_prefix} ]]; then
               echo "ERROR: --prefix <name of your vm> is required and must be a valid alpha-numeric string."
               func_help
               exit 1
           else
               devenv_prefix="$(echo $test_prefix | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/-*$//g' | sed -r 's/-{2,}/-/g' | tr '[:upper:]' '[:lower:]' | cut -c -63)"
           fi
           ;;
       --provider)
         # Currently only 2 providers, softlayer or amazon
         test_provider="$(echo -e $second_arg | awk '{print tolower($0)}')"
         if [[ " ${devenv_allowed_providers[@]} " =~ " ${test_provider} " ]]; then
           devenv_provider=${test_provider}
         else
           echo "ERROR: Please enter a valid provider: ${devenv_allowed_providers[@]}"
           exit 1
         fi
         ;;
       --nodes|-n)
           test_nodes=$second_arg
           if [[ -n "${test_nodes=~[^0-9]}" && "$test_nodes" -ge 0 && "$test_nodes" -le $devenv_max_nodes ]]; then
               devenv_nodes=$test_nodes
           else
               echo "ERROR: If --nodes or -n is specified then a valid number of nodes (between 1 and ${devenv_max_nodes}) is required."
               exit 1
           fi
           ;;
       --size|-s)
           # Test if size exists in profiles (devenv_allowed_sizes should be an array)
           test_size="$(echo -e $second_arg | awk '{print tolower($0)}')"
           if [[ " ${devenv_allowed_sizes[@]} " =~ " ${test_size} " ]]; then
             devenv_size=${test_size}
           else
             echo "ERROR: Please enter a valid size: ${devenv_allowed_sizes[@]}"
             exit 1
           fi
           ;;
       --node_size|-ns)
           # Test if size exists in profiles (devenv_allowed_sizes should be an array)
           test_size="$(echo -e $second_arg | awk '{print tolower($0)}')"
           if [[ " ${devenv_allowed_sizes[@]} " =~ " ${test_size} " ]]; then
             devenv_node_size=${test_size}
           else
             echo "ERROR: Please enter a valid node size: ${devenv_allowed_sizes[@]}"
             exit 1
           fi
           ;;
       --lifespan|-l)
           #Test if lifespan exists in up config profiles devenv_allowed_lifespans array
           test_lifespan="$(echo -e $second_arg | awk '{print tolower($0)}')"
           if [[ " ${devenv_allowed_lifespans[@]} " =~ " ${test_lifespan} " ]];
           then
               devenv_lifespan=${test_lifespan}
           else
               echo "ERROR: Please enter a valid lifespan: ${devenv_allowed_lifespans[@]}"
               exit 1
           fi
           ;;
       --branch|-b)
           devenv_branch=$second_arg
           ;;
       --master_grains|-G)
           array_master_grains+=("$second_arg")
           ;;
       --nodes_grains|-g)
           array_nodes_grains+=("$second_arg")
           ;;
       --master_minion|-M)
           array_master_minion+=("$second_arg")
           ;;
       --nodes_minion|-m)
           array_nodes_minion+=("$second_arg")
           ;;
       *)
           # Assuming this is the prefix without the "--prefix | -p" argument
           test_prefix=$primary_arg
           if [[ -z ${test_prefix} ]]; then
               echo "ERROR: --prefix <name of your vm> is required and must be a valid alpha-numeric string."
               func_help
               exit 1
           elif [[ ${test_prefix} =~ ^- ]]; then
               echo "Unknown parameter ${test_prefix}"
               func_help
               exit 1
           else
               devenv_prefix="$(echo $test_prefix | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/-*$//g' | sed -r 's/-{2,}/-/g' | tr '[:upper:]' '[:lower:]' | cut -c -63)"
           fi
           ;;
   esac
}

func_format_arrays(){
   # Format master grains for pepper.
   # I know there's a better way, but it will work for now :-)
   # Probably some array to json in bash, or just a python one-liner will make it better
   # and allow us to do sanity checks.
   if ! [[ -z ${array_master_grains} ]]; then
       for val in "${array_master_grains[@]}"; do
           if [[ "$val" != "${array_master_grains[-1]}" ]]; then
               devenv_master_grains+="${val}, "
           else
               devenv_master_grains+="${val}"
           fi
       done
   fi

   # Format master grains for pepper
   if ! [[ -z ${array_nodes_grains} ]]; then
       for val in "${array_nodes_grains[@]}"; do
           if [[ "$val" != "${array_nodes_grains[-1]}" ]]; then
               devenv_nodes_grains+="${val}, "
           else
               devenv_nodes_grains+="${val}"
           fi
       done
   fi

   # Format master minion configs for pepper
   if ! [[ -z ${array_master_minional in "${array_master_grains[@]}"; do
           if [[ "$val" != "${array_master_grains[-1]}" ]]; then
               devenv_master_grains+="${val}, "
           else
               devenv_master_grains+="${val}"
           fi
       done
   fi

   # Format master grains for pepper
   if ! [[ -z ${array_nodes_grains} ]]; then
       for val in "${array_nodesr val in "${array_nodes_minion[@]}"; do
           if [[ "$val" != "${array_nodes_minion[-1]}" ]]; then
               devenv_nodes_minion+="${val}, "
           else
               devenv_nodes_minion+="${val}"
           fi
       done
   fi
}

func_create(){
   if [[ -z ${devenv_prefix} ]]; then
      echo "ERROR: --prefix <name of your vm> is required and must be a valid alpha-numeric string."
      exit 1
   fi
   test_vm=$(func_list |grep " $devenv_prefix.${formatted_owner}")
   if [[ -z ${test_vm} ]]; then
       echo "Going to create ${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN}, please wait a few minutes."
       pepper_output=$(mktemp)
       pepper $devenv_pepper_args --json "{\"fun\":\"state.orchestrate\", \"client\":\"runner\", \"mods\":\"orch.devenv.create\", \"timeout\":${devenv_timeout}, \"pillar\":{ \"devenv_master_minion\": { ${devenv_master_minion} }, \"devenv_master_grains\": { ${devenv_master_grains} }, \"devenv_nodes_minion\": { ${devenv_nodes_minion} }, \"devenv_nodes_grains\": { ${devenv_nodes_grains} }, \"devenv_prefix\":\"${devenv_prefix}\", \"devenv_provider\":\"${devenv_provider}\", \"devenv_nodes\":\"${devenv_nodes}\", \"devenv_owner\":\"${devenv_owner}\", \"devenv_size\":\"${devenv_size}\", \"devenv_node_size\": \"${devenv_node_size}\", \"devenv_lifespan\":\"${devenv_lifespan}\", \"devenv_branch\":\"${devenv_branch}\"}}" >$pepper_output
       pepper_retcode=$(cat $pepper_output |jq '.return[0].retcode')
       if [ "$pepper_retcode" != "0" ]; then
           cat $pepper_output
           echo
           echo "ERROR: VM creation failed. Debug output from Salt shown above is also preserved in \"$pepper_output\" so you can pass it to @DevOps for research."
           exit 1
       fi
       echo "Create process complete."
       echo
       echo "To access your VM run: up ssh ${devenv_prefix}"
       echo "To terminate it: up destroy ${devenv_prefix}"
       rm $pepper_output
       exit 0
   else
       echo "${devenv_prefix} already exists."
       echo "To access it run: up ssh ${devenv_prefix}"
       echo "To terminate it: up destroy ${devenv_prefix}"
       exit 1
   fi
}

func_destroy(){
   if [[ ${confirm_destroy} == "false" ]]; then
       echo "Exiting destroy sequence.  Destroy for VM \"${devenv_prefix}\" unconfirmed."
   fi
   echo "Destroying ${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN} and its nodes (if any), please wait."
   pepper_output=$(mktemp)
   pepper $devenv_pepper_args --json "{\"fun\": \"state.orchestrate\", \"client\": \"runner\", \"mods\": \"orch.devenv.destroy\", \"pillar\": { \"devenv_prefix\": \"${devenv_prefix}\", \"devenv_owner\": \"${devenv_owner}\"}}" >$pepper_output
   pepper_retcode=$(cat $pepper_output |jq '.return[0].retcode')
   if [ $pepper_retcode != "0" ]; then
       cat $pepper_output
       echo
       echo "ERROR: VM destruction failed. Debug output from Salt shown above is also preserved in \"$pepper_output\" so you can pass it to @DevOps for research."
       exit 1
   fi
   echo "${devenv_prefix} was destroyed."
   rm $pepper_output
   exit 0
}

func_list(){
   # action to list nodes
   module_args="pretty=True"
   is_filtered="true"

   while [[ -n "$1" ]]; do
       case "$1" in
           "-a"|"a"|"--all"|"-all"|"all")
               is_filtered="false"
               shift
               ;;
           "-p"|"p"|"--showpass")
               module_args="${module_args} show_root_password=True"
               shift
               ;;
           *)
               shift
               ;;
       esac
   done

   if [[ $is_filtered == "true" ]]; then
       module_args="${module_args} owner=${formatted_owner}"
   fi

   pepper $devenv_pepper_args ${devenv_master} upsight_devenv.list ${module_args} | jq -r ".return[0][\"${DEVENV_MASTER}\"]"
}

func_grant(){
   ssh_key_url="https://keys.eng.upsight.com/${devenv_granted_user}.pub"
   granted_user_key="$(curl -s ${ssh_key_url} | grep ${devenv_granted_user})"
   # action to grant access to master node
   if ! [[ -z ${granted_user_key} ]]; then
       echo "Granting user $devenv_granted_user access to ${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN}"
       ssh -t wand@${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN} "sudo salt '*' kontagent.install_ssh_key ${devenv_granted_user}"
   else
       echo "ERROR: Could not find public SSH key at ${ssh_key_url}, please ensure that ${devenv_granted_user} has ~/.ssh/id_rsa.pub on eng1.upsight.com. Exiting."
       exit 1
   fi
}

if [[ $# -lt 1 ]]; then
   func_help
   exit 1
fi

action=$1
case $action in
   "-h" | "help" | "--help" | "-v" | "--version")
       func_help
       ;;
   create)
       if [[ $# -lt 2 ]]; then
           echo "create usage:"
           echo "$0 create [--prefix] <vm prefix> [-n, --nodes <number of nodes>] [-s, --size <size>] [-b, --branch <branch name>] [-G, --master_grains '<grain:value>'] [-g, --nodes_grains '<grain:value>'] [-M, --master_minion '<config:value>'] [-m, --nodes_minion '<config:value>']"
           exit 1
       fi

       shift
       while [ -n "$1" ]; do
           if [[ ! $1 =~ ^- ]] && [[ $2 =~ ^- ]]; then
               primary_arg="--prefix"
               sub_arg="$1"
               func_set_args $primary_arg $sub_arg
               shift
           fi
           primary_arg="$1"
           shift
           sub_arg="$1"
           func_set_args $primary_arg $sub_arg
           shift
       done

       # format arrays for pepper
       func_format_arrays

       # CREATE VM CLUSTER
       func_create
       exit 0
       ;;
   destroy)
       if [ "$#" == 1 ] || [ "$#" -gt 3 ]; then
           echo "destroy usage:"
           echo "$0 destroy [-y, --yes] <vm prefix>"
           exit 1
       fi

       confirm_destroy="false"
       destroy_args=($2 $3)
       for i in "${destroy_args[@]}"
       do
           case $i in
               "-y" | "--yes")
                   confirm_destroy="true"
                   ;;
               *)
                   primary_arg="--prefix"
                   sub_arg="$i"
                   func_set_args $primary_arg $sub_arg
                   ;;
           esac
       done
       # Test if the VM exists
       test_vm=$(func_list |grep " $devenv_prefix.${formatted_owner}")
       if [[ -z ${test_vm} ]]; then
           echo "WARNING: ${devenv_prefix} not found.  No action taken."
           exit 0
       fi

       if [[ ${confirm_destroy} == "false" ]]; then
           read -p "Are you sure you want to destroy VM \"${devenv_prefix}\" (y/n)? " choice
           case "$choice" in
               "y" | "Y")
                   confirm_destroy="true"
                   ;;
               *)
                   exit 1
                   ;;
           esac
       fi

       # Destroy VM
       func_destroy
       exit 0
       ;;
   list)
       # List vms for $SALTAPI_USER
       shift
       func_list "$@"
       exit 0
       ;;
   grant)
       if [[ $# -ne 3 ]]; then
           echo "grant usage:"
           echo "$0 grant <user.name> <vm prefix>"
           exit 1
       fi
       devenv_granted_user="$2"
       primary_arg="--prefix"
       sub_arg="$3"
       func_set_args $primary_arg $sub_arg

       # Grant Access
       func_grant

      exit 0
       ;;
   ssh)
       if [[ $# -lt 2 ]]; then
           echo "ssh usage:"
           echo "$0 ssh <vm prefix> [owner.name]"
           exit 1
       fi
       primary_arg="--prefix"
       sub_arg="$2"
       func_set_args $primary_arg $sub_arg

       if [ $# -gt 2 ]; then
           formatted_owner=$(echo $3 | tr . -)
       fi

       echo -e "Connecting to 'ssh wand@${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN}'\n"
       ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no wand@${devenv_prefix}.${formatted_owner}.${SALT_CLOUD_SUBDOMAIN}.${SALT_CLOUD_DOMAIN}
       ;;
   *)
       # unknown option
       echo "ERROR: Incorrect argument provided: $action"
       func_help
       exit 1
       ;;
esac
