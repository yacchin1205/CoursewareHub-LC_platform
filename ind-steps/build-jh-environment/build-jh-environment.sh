#!/bin/bash

reportfailed()
{
    echo "Script failed...exiting. ($*)" 1>&2
    exit 255
}

export ORGCODEDIR="$(cd "$(dirname $(readlink -f "$0"))" && pwd -P)" || reportfailed

DATADIR="$1"

[ -L "$1/build-jh-environment.sh" ] || reportfailed "First parameter must be the datadir"

DATADIR="$(readlink -f "$DATADIR")"

source "$ORGCODEDIR/simple-defaults-for-bashsteps.source"

# Maybe the multiple build scripts in this directory could share the
# same .conf, but overall it is probably simpler to keep them
# separate.  Hopefully there will be time to revisit this decision
# when thinking more about best practices for bashsteps and $DATADIR.

DATADIRCONF="$DATADIR/datadir-jh.conf"

# avoids errors on first run, but maybe not good to change state
# outside of a step
touch  "$DATADIRCONF"

source "$DATADIRCONF"

# These are expected to exist before running the first time:
conffiles=(
    datadir-jh.conf
    datadir-jh-hub.conf
    $(
	for i in $node_list; do
	    echo datadir-jh-$i.conf
	done
    )
)

for i in "${conffiles[@]}"; do
    [ -f "$DATADIR/$i" ] || reportfailed "$i is required"
done

## This script assumes link to ubuntu image is already at
## "$DATADIR/ubuntu-image-links/ubuntu-image.tar.gz"

VMDIR=jhvmdir

(
    $starting_group "Setup clean VM for hub and nodes"
    # not currently snapshotting this VM, but if the next snapshot exists
    # then this group can be skipped.
    [ -f "$DATADIR/$VMDIR/ubuntu-before-nbgrader.tar.gz" ]
    $skip_group_if_unnecessary

    (
	$starting_step "Make $VMDIR"
	[ -d "$DATADIR/$VMDIR" ]
	$skip_step_if_already_done ; set -e
	mkdir "$DATADIR/$VMDIR"
	# increase default mem to give room for a wakame instance or two
	echo ': ${KVMMEM:=4096}' >>"$DATADIR/$VMDIR/datadir.conf"
	[ -f "$DATADIR/datadir-jh.conf" ] || reportfailed "datadir-jh.conf is required"
	cat "$DATADIR/datadir-jh.conf" >>"$DATADIR/$VMDIR/datadir.conf"
    ) ; prev_cmd_failed

    DATADIR="$DATADIR/$VMDIR" \
	   "$ORGCODEDIR/ind-steps/kvmsteps/kvm-setup.sh" \
	   "$DATADIR/ubuntu-image-links/ubuntu-image.tar.gz"
    # TODO: this guard is awkward.
    [ -x "$DATADIR/$VMDIR/kvm-boot.sh" ] && \
	"$DATADIR/$VMDIR/kvm-boot.sh"

    (
	$starting_step "Allow sudo for ubuntu user account, remove mtod"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    SSHUSER=root "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
grep 'ubuntu.*ALL' /etc/sudoers >/dev/null
EOF
	$skip_step_if_already_done ; set -e

	SSHUSER=root "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
echo 'ubuntu ALL=(ALL) NOPASSWD: ALL' >>/etc/sudoers
rm /etc/update-motd.d/*
EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Added step to give VMs 8.8.8.8 for dns"
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
grep -F "8.8.8.8" /etc/dhcp/dhclient.conf
EOF
	$skip_step_if_already_done

	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
# the next line is necessary or docker pulls do not work reliably
# related: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=625689
echo "prepend domain-name-servers 8.8.8.8;" | sudo tee -a /etc/dhcp/dhclient.conf
EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Install git"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
which git
EOF
	$skip_step_if_already_done ; set -e

	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
sudo apt-get update
sudo apt-get -y install git
EOF
    ) ; prev_cmd_failed

    (
	$starting_group "Install ansible from source"
	# Installing from source because of note here:
	# https://github.com/compmodels/jupyterhub-deploy#deploying
	# also because install with "apt-get -y install ansible" raised this
	# problem: http://tracker.ceph.com/issues/12380

	#  Source install instructions:
	#  https://michaelheap.com/installing-ansible-from-source-on-ubuntu/
	#  http://docs.ansible.com/ansible/intro_installation.html

	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
which ansible
EOF
	$skip_group_if_unnecessary

	(
	    $starting_step "Install ansible build dependencies"
	    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
		"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
false # always do this, let group block it
EOF
	    $skip_step_if_already_done ; set -e

	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
sudo apt-get update
sudo apt-get -y install python2.7 python-yaml python-paramiko python-jinja2 python-httplib2 make python-pip
EOF
	) ; prev_cmd_failed

	(
	    $starting_step "Clone ansible repository"
	    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
		"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -d ansible ]
EOF
	    $skip_step_if_already_done ; set -e

	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -e

### git clone https://github.com/ansible/ansible.git --recursive

git clone https://github.com/ansible/ansible.git
cd ansible

# reset to older version so that this error does not occur:
#
# TASK [nfs_server : bind home volume] *******************************************
# fatal: [hub]: FAILED! => {"changed": false, "failed": true, "msg": "Error mounting //home: /bin/mount: invalid option -- 'T'

git reset --hard a2d0bbed8c3f9de5d9c993e9b6f27f8af3eea438
git submodule update --init --recursive

EOF
	) ; prev_cmd_failed

	(
	    $starting_step "Make/install ansible"
	    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
		"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -x /usr/local/bin/ansible ]
EOF
	    $skip_step_if_already_done ; set -e

	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -e
cd ansible
sudo make install
EOF
	) ; prev_cmd_failed

    ) ; prev_cmd_failed

    (
	$starting_step "Clone https://github.com/(compmodels)/jupyterhub-deploy.git"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -d jupyterhub-deploy ]
EOF
	$skip_step_if_already_done ; set -e

	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
# clone from our exploration/debugging copy
git clone https://github.com/triggers/jupyterhub-deploy.git
#git clone https://github.com/compmodels/jupyterhub-deploy.git
EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Adjust ansible config files for node_list"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null
[ -f nodelist ] && [ "\$(cat nodelist)" = "$node_list" ]
EOF
	$skip_step_if_already_done ; set -e

	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
node_list="$node_list"

[ -f jupyterhub-deploy/inventory.bak ] || cp jupyterhub-deploy/inventory jupyterhub-deploy/inventory.bak 

while IFS='' read -r ln ; do
   case "\$ln" in
     *jupyterhub_nodes*)
         echo "\$ln"
         for n in \$node_list; do
            echo \$n ansible_ssh_user=root ansible_ssh_host=192.168.11."\${n#node}" fqdn=\$n servicenet_ip=192.168.11."\${n#node}"
         done
         while IFS='' read -r ln ; do
             [[ "\$ln" == [* ]] && break
         done
         echo
         echo "\$ln"
         ;;
     *nfs_clients*)
         echo "\$ln"
         for n in \$node_list; do
            echo \$n
         done
         while IFS='' read -r ln ; do
             [[ "\$ln" == [* ]] && break
         done
         echo "\$ln"
         ;;
     *) echo "\$ln"
        ;;
   esac
done <jupyterhub-deploy/inventory.bak  >jupyterhub-deploy/inventory

[ -f jupyterhub-deploy/script/assemble_certs.bak ] || cp jupyterhub-deploy/script/assemble_certs jupyterhub-deploy/script/assemble_certs.bak

while IFS='' read -r ln ; do
   case "\$ln" in
     name_map\ =*)
         echo "\$ln"
         echo -n '    "hub": "hub"'
         for n in \$node_list; do
            echo ','
            printf '    "%s": "%s"' "\$n" "\$n"
         done
         while IFS='' read -r ln ; do
             [[ "\$ln" == }* ]] && break
         done
         echo
         echo "\$ln"
         ;;
     *) echo "\$ln"
        ;;
   esac
done <jupyterhub-deploy/script/assemble_certs.bak  >jupyterhub-deploy/script/assemble_certs
echo ------ jupyterhub-deploy/inventory ------------
diff jupyterhub-deploy/inventory.bak jupyterhub-deploy/inventory || :
echo ------ jupyterhub-deploy/script/assemble_certs ---------
diff  jupyterhub-deploy/script/assemble_certs.bak jupyterhub-deploy/script/assemble_certs || :
EOF
    ) ; prev_cmd_failed
) ; prev_cmd_failed

(
    $starting_group "Snapshot base KVM image"
    [ -f "$DATADIR/$VMDIR/ubuntu-before-nbgrader.tar.gz" ]
    $skip_group_if_unnecessary

    [ -x "$DATADIR/$VMDIR/kvm-shutdown-via-ssh.sh" ] && \
	"$DATADIR/$VMDIR/kvm-shutdown-via-ssh.sh"

    (
	$starting_step "Make snapshot of base image"
	[ -f "$DATADIR/$VMDIR/ubuntu-before-nbgrader.tar.gz" ]
	$skip_step_if_already_done ; set -e
	cd "$DATADIR/$VMDIR/"
	tar czSvf  ubuntu-before-nbgrader.tar.gz ubuntu-14-instance-build.img
    ) ; prev_cmd_failed

) ; prev_cmd_failed

(
    $starting_group "Boot three VMs"

    boot-one-vm()
    {
	avmdir="$1"
	(
	    $starting_step "Make $avmdir"
	    [ -d "$DATADIR/$avmdir" ]
	    $skip_step_if_already_done ; set -e
	    mkdir "$DATADIR/$avmdir"
	    # increase default mem to give room for a wakame instance or two
	    echo ': ${KVMMEM:=4096}' >>"$DATADIR/$avmdir/datadir.conf"
	    [ -f "$DATADIR/$3" ] || reportfailed "$3 is required"
	    # copy specific port forwarding stuff to avmdir, so vmdir*/kvm-* scripts
	    # will have all config info
	    cat "$DATADIR/$3" >>"$DATADIR/$avmdir/datadir.conf"
	    # copy ssh info from main VM to note VMs:
	    cp "$DATADIR/$VMDIR/sshuser" "$DATADIR/$avmdir/sshuser"
	    cp "$DATADIR/$VMDIR/sshkey" "$DATADIR/$avmdir/sshkey"
	) ; prev_cmd_failed

	if ! [ -x "$DATADIR/$avmdir/kvm-boot.sh" ]; then
	    DATADIR="$DATADIR/$avmdir" \
		   "$ORGCODEDIR/ind-steps/kvmsteps/kvm-setup.sh" \
		   "$DATADIR/$VMDIR/ubuntu-before-nbgrader.tar.gz"
	fi
	# Note: the (two) steps above will be skipped for the main KVM

	(
	    $starting_step "Expand fresh image from snapshot for $2"
	    [ -f "$DATADIR/$avmdir/ubuntu-14-instance-build.img" ]
	    $skip_step_if_already_done ; set -e
	    cd "$DATADIR/$avmdir/"
	    tar xzSvf ../$VMDIR/ubuntu-before-nbgrader.tar.gz
	) ; prev_cmd_failed

	# TODO: this guard is awkward.
	[ -x "$DATADIR/$avmdir/kvm-boot.sh" ] && \
	    "$DATADIR/$avmdir/kvm-boot.sh"
	
	(
	    $starting_step "Setup private network for VM $avmdir"
	    "$DATADIR/$avmdir/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
grep eth1 /etc/network/interfaces
EOF
	    $skip_step_if_already_done
	    addr=$(
		case "$2" in
		    *main*) echo 99 ;;
		    *hub*) echo 88 ;;
		    node*) echo "${2//[^0-9]}" ;; #TODO: refactor
		    *) reportfailed "BUG"
		esac
		)

	    # http://askubuntu.com/questions/441619/how-to-successfully-restart-a-network-without-reboot-over-ssh
	    "$DATADIR/$avmdir/ssh-to-kvm.sh" <<EOF
sudo tee -a /etc/network/interfaces <<EOF2

auto eth1
iface eth1 inet static
    address 192.168.11.$addr
    netmask 255.255.255.0
EOF2

# sudo ifdown eth1
sudo ifup eth1

EOF
	) ; prev_cmd_failed

	(
	    $starting_step "Change hostname VM $avmdir"
	    "$DATADIR/$avmdir/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
[[ "\$(hostname)" != *ubuntu* ]]
EOF
	    $skip_step_if_already_done
	    hn=$(
		case "$2" in
		    *main*) echo main ;;
		    *hub*) echo hub ;;
		    node*)
			tmpv="${2%KVM*}"
			echo "${tmpv// /}"   #TODO: refactor
			;;
		    *) reportfailed "BUG"
		esac
		)

	    "$DATADIR/$avmdir/ssh-to-kvm.sh" <<EOF
echo $hn | sudo tee /etc/hostname
echo 127.0.0.1 $hn | sudo tee -a /etc/hosts
sudo hostname $hn
EOF
	) ; prev_cmd_failed
    }

    boot-one-vm "$VMDIR" "main KVM" datadir-jh.conf
    boot-one-vm "$VMDIR-hub" "hub KVM" datadir-jh-hub.conf
    for n in $node_list; do
	boot-one-vm "$VMDIR-$n" "$n KVM" datadir-jh-$n.conf
    done

) ; prev_cmd_failed

(
    $starting_step "Make sure mac addresses were configured"
    # Make sure all three mac addresses are unique
    nodesarray=( $node_list )
    vmcount=$(( ${#nodesarray[@]} + 2 )) # nodes + hub + ansible/main
    [ $(grep -ho 'export.*mcastMAC.*' "$DATADIR"/jhvmdir*/*conf | sort -u | wc -l) -eq "$vmcount" ]
    $skip_step_if_already_done
    # always fail if this has not been done
    reportfailed "Add mcastMAC= to: datadir-jh.conf datadir-jh-nodennn.conf"
) ; prev_cmd_failed

(
    $starting_group "Make TLS/SSL certificates with docker"
    (
	$starting_step "Install Docker in main KVM"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] && {
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<<"which docker" 2>/dev/null 1>&2
	}
	$skip_step_if_already_done; set -e
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" "curl -fsSL https://get.docker.com/ | sudo sh"
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" "sudo usermod -aG docker ubuntu"
	touch "$DATADIR/extrareboot" # necessary to make the usermod take effect in Jupyter environment
    ) ; prev_cmd_failed

    if [ "$extrareboot" != "" ] || \
	   [ -f "$DATADIR/extrareboot" ] ; then  # this flag can also be set before calling ./build-nii.sh
	rm -f "$DATADIR/extrareboot"
	[ -x "$DATADIR/$VMDIR/kvm-shutdown-via-ssh.sh" ] && \
	    "$DATADIR/$VMDIR/kvm-shutdown-via-ssh.sh"
    fi

    if [ -x "$DATADIR/$VMDIR/kvm-boot.sh" ]; then
	"$DATADIR/$VMDIR/kvm-boot.sh"
    fi


    # following guide at: https://github.com/compmodels/jupyterhub-deploy/blob/master/INSTALL.md

    KEYMASTER="docker run --rm -v /home/ubuntu/jupyterhub-deploy/certificates/:/certificates/ cloudpipe/keymaster"

    (
	$starting_step "Gather random data from host, set vault-password"
	[ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -f jupyterhub-deploy/certificates/password ]
EOF
	$skip_step_if_already_done ; set -e

	# The access to /dev/random must be done on the host because
	# it hangs in KVM
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
mkdir -p jupyterhub-deploy/certificates

echo ubuntu >/home/ubuntu/jupyterhub-deploy/vault-password

cat >jupyterhub-deploy/certificates/password <<EOF2
$(cat /dev/random | head -c 128 | base64)
EOF2

${KEYMASTER} ca

EOF
    ) ; prev_cmd_failed

    do-one-keypair()
    {
	(
	    $starting_step "Generate a keypair for a server $1"
	    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
		"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -f /home/ubuntu/jupyterhub-deploy/certificates/$1-key.pem ]
EOF
	    $skip_step_if_already_done ; set -e
	    
	    # The access to /dev/random must be done on the host because
	    # it hangs in KVM
	    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -e
set -x
cd jupyterhub-deploy/certificates
${KEYMASTER} signed-keypair -n $1 -h $1.website.com -p both -s IP:192.168.11.$2
EOF
	) ; prev_cmd_failed
    }
    do-one-keypair hub 88
    for n in $node_list; do
	do-one-keypair "$n" "${n//[^0-9]/}"
    done
)


(
    exit 0  # The contents here are now part of triggers/jupyterhub-deploy.git
    $starting_step "Set secrets.vault"
    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -f /home/ubuntu/jupyterhub-deploy/secrets.vault.yml.org ]
EOF
    $skip_step_if_already_done ; set -e
    
    # The access to /dev/random must be done on the host because
    # it hangs in KVM
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -e
set -x
cd jupyterhub-deploy/
cp secrets.vault.yml secrets.vault.yml.org

# not sure yet how to set this:
cp secrets.vault.yml.example secrets.vault.yml

sed -i "s,.*other_ssh_keys.*,other_ssh_keys: [ '\$(< "/home/ubuntu/.ssh/authorized_keys")' ]," secrets.vault.yml

sed -i "s,.*configproxy_auth_token.*,configproxy_auth_token: '2fd34c8b5dc9ba64754e754114f37a7b33eff14b7f415e4f761d28a6b516a3be'," secrets.vault.yml

sed -i "s,.*jupyterhub_admin_user.*,jupyterhub_admin_user: 'ubuntu'," secrets.vault.yml

sed -i "s,.*cookie_secret.*,cookie_secret: 'cookie_secret'," secrets.vault.yml

cp secrets.vault.yml secrets.vault.yml.tmp-for-debugging

ansible-vault encrypt --vault-password-file vault-password secrets.vault.yml
EOF
) ; prev_cmd_failed

(
    $starting_step "Set users.vault"
    [ -x "$DATADIR/$VMDIR/ssh-to-kvm.sh" ] &&
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>/dev/null
[ -f /home/ubuntu/jupyterhub-deploy/users.vault.yml.org ]
EOF
    $skip_step_if_already_done ; set -e
    
    # The access to /dev/random must be done on the host because
    # it hangs in KVM
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -e
set -x
cd jupyterhub-deploy/
cp users.vault.yml users.vault.yml.org
cat >users.vault.yml <<EOF2
jupyterhub_admins:
- potter
EOF2
ansible-vault encrypt --vault-password-file vault-password users.vault.yml
EOF
) ; prev_cmd_failed

(
    $starting_step "Copy private ssh key to main KVM, plus minimal ssh config"
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null
[ -f .ssh/id_rsa ]
EOF
    $skip_step_if_already_done
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -x

cat >.ssh/id_rsa <<EOF2
$(< "$DATADIR/$VMDIR/sshkey")
EOF2
chmod 600 .ssh/id_rsa

cat >.ssh/config <<EOF2
Host *
        StrictHostKeyChecking no
        TCPKeepAlive yes
        UserKnownHostsFile /dev/null
	ForwardAgent yes
EOF2
chmod 644 .ssh/config

EOF
) ; prev_cmd_failed

(
    $starting_step "Run ./script/assemble_certs (from the jupyterhub-deploy repository)"
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null
cd jupyterhub-deploy
[ -f ./host_vars/node2 ]
EOF
    $skip_step_if_already_done
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -x
set -e

cd jupyterhub-deploy
./script/assemble_certs 

EOF
) ; prev_cmd_failed

(
    $starting_step "Copy user ubuntu's .ssh dir to shared NFS area"
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null 1>&2
[ -d /mnt/nfs/home/ubuntu/.ssh ]
EOF
    $skip_step_if_already_done
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF
set -x
set -e

sudo mkdir -p /mnt/nfs
sudo tar c /home/ubuntu/.ssh | ( cd /mnt/nfs && sudo tar xv )

EOF
) ; prev_cmd_failed

(
    $starting_step "Run main **Ansible script** (from the jupyterhub-deploy repository)"
    nodesarray=( $node_list )
    vmcount=$(( ${#nodesarray[@]} + 1 )) # nodes + just the hub
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null
cd jupyterhub-deploy
# last part of ansible log should show "failed=0" three times. e.g:
#   PLAY RECAP *********************************************************************
#   hub                        : ok=97   changed=84   unreachable=0    failed=0   
#   node1                      : ok=41   changed=32   unreachable=0    failed=0   
#   node2                      : ok=41   changed=32   unreachable=0    failed=0   
count="\$(tail deploylog.log | grep -o "failed=0" | wc -l)"
[ "\$count" -eq "$vmcount" ]
EOF
    $skip_step_if_already_done
    "$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
set -x
set -e

cd jupyterhub-deploy
time ./script/deploy | tee -a deploylog.log

EOF
) ; prev_cmd_failed

(
    $starting_step "Copy proxy's certificate and key to hub VM"
    # TODO: find out why Ansible step did not do this correctly.
    # When using Ansible to do this, all the end of line characters
    # were stripped out.
    # Note: the root_nginx_1 container probably needs restarting,
    #       which seems to happen automatically eventually.
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
lines=\$(cat /tmp/proxykey /tmp/proxycert | wc -l)
[ "\$lines" -gt 10 ]
EOF
    $skip_step_if_already_done
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF
set -x
set -e

# For now, just reusing the self-signed cert used for the hub.

sudo tee /tmp/proxycert <<EOF2
$("$DATADIR/$VMDIR/ssh-to-kvm.sh" cat jupyterhub-deploy/certificates/hub-cert.pem)
EOF2

sudo tee /tmp/proxykey <<EOF3
$("$DATADIR/$VMDIR/ssh-to-kvm.sh" cat jupyterhub-deploy/certificates/hub-key.pem)
EOF3

EOF
) ; prev_cmd_failed

(
    $starting_step "Copy manage-tools to hub VM"
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" -q <<EOF 2>/dev/null >/dev/null
[ -f /jupyter/admin/admin_tools/00_GuidanceForTeacher.ipynb ]
EOF
    $skip_step_if_already_done; set -e
    cd "$DATADIR"
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" rm -fr /tmp/manage-tools
    tar cz manage-tools | \
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" tar xzv -C /tmp
    "$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" -q <<EOF
    set -e
    # mkdir stuff is also in multihubctl, but needed here
    # because multihubctl has not been run yet.
    sudo mkdir -p /jupyter/admin/{admin_tools,tools}
    sudo chmod a+wr /jupyter/admin/{admin_tools,tools}

    sudo cp /tmp/manage-tools/admin-tools/* /jupyter/admin/admin_tools
    sudo cp /tmp/manage-tools/tools/* /jupyter/admin/tools

    sudo cp /tmp/manage-tools/common/* /jupyter/admin/admin_tools
    sudo cp /tmp/manage-tools/common/* /jupyter/admin/tools

    cd /jupyter/admin
    sudo chmod 444  */*ipynb
    sudo chmod 555 tools/notebook-diff admin_tools/notebook-diff admin_tools/collect-answer
EOF
) ; prev_cmd_failed

(
     $starting_group "Build TensorFlow container image"
     [ -f "$DATADIR/tensorflow-image.tar" ]
     $skip_group_if_unnecessary
     
     (
	 $starting_step "Upload a DockerFile and other files for the Tensorflow Ubuntu container"
	 "$DATADIR/$VMDIR-node1/ssh-to-kvm.sh" -q '[ -d /srv/tensorflow-ubuntu ]'
	 $skip_step_if_already_done; set -e
	 (
	     cd "$DATADIR"
	     tar c tensorflow-ubuntu
	 ) | "$DATADIR/$VMDIR-node1/ssh-to-kvm.sh" sudo tar xv -C /srv
     ) ; prev_cmd_failed
     
     (
	 $starting_step "Run 'docker build' for the Tensorflow container"
	 images="$("$DATADIR/$VMDIR-node1/ssh-to-kvm.sh" -q sudo docker images)"
	 grep -w '^tensorflow' <<<"$images"  1>/dev/null
	 $skip_step_if_already_done
	 "$DATADIR/$VMDIR-node1/ssh-to-kvm.sh" -q sudo bash <<EOF
cd  /srv/tensorflow-ubuntu
docker build -t tensorflow ./
EOF
     ) ; prev_cmd_failed

     (
	 $starting_step "Download snapshot of the Tensorflow container"
	 [ -f "$DATADIR/tensorflow-image.tar" ]
	 $skip_step_if_already_done
	 "$DATADIR/$VMDIR-node1/ssh-to-kvm.sh" -q sudo bash >"$DATADIR/tensorflow-image.tar" <<EOF 
docker save tensorflow
EOF
	 echo "tensorflow" >"$DATADIR/tensorflow-image.tar.uniquename" # used by bin/serverctl
     ) ; prev_cmd_failed
) ; prev_cmd_failed

do_distribute_one_image()
{
    anode="$1"
    (
	$starting_step "Upload tensorflow image to $anode"
	images="$("$DATADIR/$VMDIR-$anode/ssh-to-kvm.sh" -q sudo docker images)"
	grep '^tensorflow' <<<"$images"  1>/dev/null
	$skip_step_if_already_done ; set -e
	"$DATADIR/$VMDIR-$anode/ssh-to-kvm.sh" -q sudo docker load <"$DATADIR/tensorflow-image.tar"
    ) ; prev_cmd_failed
}

for n in $node_list; do
    do_distribute_one_image "$n"
done

(
    $starting_group "Misc steps"

    (
	$starting_step "Clone old repository that has notebooks"
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
[ -d /srv/nii-project-2016 ]
EOF
	$skip_step_if_already_done
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF
set -x
set -e

cd /srv
sudo git clone https://github.com/axsh/nii-project-2016.git

EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Download Oracle Java rpm"
	targetfile=jdk-8u73-linux-x64.rpm
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
[ -f /srv/nii-project-2016/notebooks/.downloads/$targetfile ]
EOF
	$skip_step_if_already_done; set -e
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF
        set -x
        set -e
	sudo mkdir -p "/srv/nii-project-2016/notebooks/.downloads"
	sudo wget --progress=dot:mega --no-check-certificate --no-cookies \
	     --header "Cookie: oraclelicense=accept-securebackup-cookie" \
	     http://download.oracle.com/otn-pub/java/jdk/8u73-b02/$targetfile \
	     -O "/srv/nii-project-2016/notebooks/.downloads/$targetfile"
EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Copy in adapt-notebooks-for-user.sh and background-command-processor.sh"
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
[ -f /srv/adapt-notebooks-for-user.sh ] && [ -f /srv/background-command-processor.sh ]
EOF
	$skip_step_if_already_done; set -e
	cd "$DATADIR"
	tar c adapt-notebooks-for-user.sh background-command-processor.sh | "$VMDIR-hub/ssh-to-kvm.sh" sudo tar xv -C /srv
    ) ; prev_cmd_failed

    (
	$starting_step "Clone sshuttle to 192.168.11.99 VM"
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
which sshuttle
EOF
	$skip_step_if_already_done; set -e
	"$DATADIR/$VMDIR/ssh-to-kvm.sh" <<EOF
git clone https://github.com/apenwarr/sshuttle.git
echo "hint: sshuttle -l 0.0.0.0 -vr centos@192.168.11.90 10.0.2.0/24" >sshuttle-hint
cd sshuttle
sudo ./setup.py install
EOF
    ) ; prev_cmd_failed

    (
	$starting_step "Start background-command-processor.sh in background on 192.168.11.88 (hub) VM"
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF 2>/dev/null >/dev/null
ps auxwww | grep 'background-command-processo[r]' 1>/dev/null 2>&1
EOF
	$skip_step_if_already_done; set -e
	"$DATADIR/$VMDIR-hub/ssh-to-kvm.sh" <<EOF
set -x
cd /srv
sudo bash -c 'setsid ./background-command-processor.sh 1>>bcp.log 2>&1 </dev/null &'
EOF
    ) ; prev_cmd_failed
) ; prev_cmd_failed

touch "$DATADIR/flag-inital-build-completed"
