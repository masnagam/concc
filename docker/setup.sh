export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends fuse3 gosu libglib2.0-0 ssh sshpass
apt-get install -y --no-install-recommends strace  # for tracing syscalls
apt-get install -y --no-install-recommends time  # for measurements

sed -i 's|#PasswordAuthentication yes|PasswordAuthentication no|' /etc/ssh/sshd_config

ssh-keygen -q -t ed25519 -N '' -f $HOME/.ssh/id_ed25519
cp $HOME/.ssh/id_ed25519.pub $HOME/.ssh/authorized_keys
cat <<'EOF' >$HOME/.ssh/config
Host *
  StrictHostKeyChecking no
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlMaster auto
  ControlPersist 1m
EOF

# cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/tmp/*
