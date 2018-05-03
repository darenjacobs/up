#!/bin/env python2.7

import datetime
import glob
import os
import time

import boto.ec2
import SoftLayer
from prettytable import PrettyTable

__salt__ = None

DOMAIN = "upsight-vm.com"


def _parse_map_files():
    '''
    Returns expiration dates for each owner.prefix combination.
    '''

    map_files_dict = {}

    for name in glob.glob('/etc/salt/cloud.maps.d/*.map'):
        with open(name) as map_file:
            created = None
            lifespan = None

            for line in map_file:
                if line.startswith("# create_ts:"):
                    created = int(line.split(" ")[2].strip())
                if line.startswith("# lifespan:"):
                    lifespan = int(line.split(" ")[2].strip())

            if created and lifespan:
                # Need to add create_ts and lifespan to get expiration
                expiration = created + lifespan
                owner_prefix = os.path.basename(name).replace(".map", "")
                map_files_dict[owner_prefix] = time.strftime("%Y-%m-%d %H:%M", time.gmtime(expiration))

    return map_files_dict


def _fetch_ec2_instances():
    '''
    Returns list of all DevEnv VMs running in Amazon EC2.
    '''

    # Prices are as of 10/17/2017 based on "grep t2.type | grep per" of this file:
    # https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-west-2/index.json
    # with EBS costs added.
    ebs_per_gigabyte_hour = 0.10 / 24 / 30

    prices = {
        "t2.micro": 0.0116 + 25 * ebs_per_gigabyte_hour,
        "t2.small": 0.0232 + 25 * ebs_per_gigabyte_hour,
        "t2.medium": 0.0464 + 25 * ebs_per_gigabyte_hour,
        "t2.large": 0.0928 + ebs_per_gigabyte_hour,
    }

    results = []
    now = datetime.datetime.now()

    region = __salt__['ktpillar.get']('salt:cloud:providers:aws:location')
    ec2 = boto.ec2.connect_to_region(region)

    for reservation in ec2.get_all_reservations():
        for vm in reservation.instances:
            result = {"provider": "aws", "hostname": "Unknown"}
            is_devenv_vm = False

            for tag in vm.tags:
                if tag == "Name":
                    result["hostname"] = vm.tags[tag]
                if tag == "DevEnv" and vm.tags[tag] == "True":
                    is_devenv_vm = True

            # Skip the loop if this is not a DevEnv VM
            if not is_devenv_vm or "DEL" in result["hostname"]:
                continue

            result["ip"] = vm.private_ip_address
            result["specs"] = vm.instance_type
            result["state"] = vm.state
            result["cost_hr"] = prices.get(vm.instance_type, 0)

            launch_time = datetime.datetime.strptime(vm.launch_time, "%Y-%m-%dT%H:%M:%S.000Z")

            age = now.replace(tzinfo=None) - launch_time.replace(tzinfo=None)
            age_hours = (24 * age.days) + (age.seconds / 3600)
            result["cost_total"] = age_hours * result["cost_hr"]

            results.append(result)

    return results


def _fetch_softlayer_instances():
    '''
    Returns list of all DevEnv VMs running at SoftLayer.
    '''
    client = SoftLayer.Client()
    manager = SoftLayer.VSManager(client)

    mask = "mask[id,operatingSystem[passwords],fullyQualifiedDomainName,primaryBackendIpAddress,maxCpu,maxMemory,datacenter,createDate,billingItem[id,nextInvoiceTotalRecurringAmount,currentHourlyCharge,hoursUsed]]"

    results = []
    now = datetime.datetime.now()

    for vm in manager.list_instances(mask=mask):
        result = {"provider": "softlayer"}

        result["hostname"] = vm.get("fullyQualifiedDomainName")
        result["ip"] = vm.get("primaryBackendIpAddress")
        result["specs"] = "%s CPU, %s MB RAM" % (vm.get("maxCpu"), vm.get("maxMemory"))
        result["state"] = "running"  # TODO, if we ever support stop/start for SL

        total = float(vm.get("billingItem", {}).get("currentHourlyCharge", 0))
        hours_used = float(vm.get("billingItem", {}).get("hoursUsed", 1))
        result["cost_hr"] = total / hours_used

        create_date = datetime.datetime.strptime(vm.get("createDate"), "%Y-%m-%dT%H:%M:%S+00:00")
        age = now.replace(tzinfo=None) - create_date.replace(tzinfo=None)
        age_hours = (24 * age.days) + (age.seconds / 3600)
        result["cost_total"] = age_hours * result["cost_hr"]

        try:
            result["password"] = vm.get("operatingSystem").get("passwords")[0].get('password')
        except:
            result["password"] = "Unknown"

        if DOMAIN in result["hostname"]:
            results.append(result)

    return results


def _get_owner_and_prefix(hostname):
    '''
    Returns VM prefix and owner, based on our prefix.owner.eng.dc.upsight-v.com
    pattern for hostnames.
    '''
    try:
        owner_name = hostname.split(".")[1]
        prefix = hostname.split(".")[0]

        if "-node" in prefix:
            prefix = prefix.split("-node")[0]
    except:
        owner_name = "Unknown"
        prefix = "Unknown"

    return owner_name, prefix


def list(pretty=False, owner=None, show_root_password=False, *args, **kwargs):
    '''
    Returns list of DevEnv VMs and their pricing information. Output can
    formatted as an ASCII table, which is used by "up list".
    '''

    instances = _fetch_ec2_instances() + _fetch_softlayer_instances()

    if not pretty:
        return instances
    else:
        expirations = _parse_map_files()

        table = PrettyTable()
        field_names = ["IP Address", "Hostname", "Owner", "Specs", "Provider", "Cost", "Expiration", "State", "Password"]
        table.field_names = field_names
        table.align["IP Address"] = "l"
        table.align["Hostname"] = "r"
        table.align["Owner"] = "l"
        table.align["Specs"] = "l"
        table.align["Provider"] = "l"
        table.align["Cost"] = "r"
        table.align["Expiration"] = "l"
        table.align["State"] = "l"
        table.align["Password"] = "l"
        table.sortby = "Owner"

        for vm in instances:
            vm_owner, prefix = _get_owner_and_prefix(vm["hostname"])

            if owner is None or owner == vm_owner:
                owner_prefix = "%s.%s" % (vm_owner, prefix)
                cost = "$%.2f ($%.3f/hr)" % (vm.get("cost_total"), vm.get("cost_hr"))

                row = []
                row.append(vm.get("ip"))
                row.append(vm.get("hostname"))
                row.append(vm_owner)
                row.append(vm.get("specs"))
                row.append(vm.get("provider"))
                row.append(cost)
                row.append(expirations.get(owner_prefix, "Unknown"))
                row.append(vm.get("state"))
                row.append(vm.get("password", "None"))

                table.add_row(row)

        fields = ["IP Address", "Hostname", "Specs", "Provider", "Cost", "Expiration", "State"]
        if show_root_password:
            fields.append("Password")
        return table.get_string(fields=fields)


if __name__ == "__main__":
    '''
    Used for testing this module outside of Salt. You need to have ~/.softlayer and
    ~/.aws/credentials configured.
    '''
    print(list(pretty=True, show_root_password=False))
    print(list(pretty=True, show_root_password=True, owner="james-hui"))
