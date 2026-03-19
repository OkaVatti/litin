# Litin

A modern, minimal init system for Linux. Supervisor-first,
shell-friendly service definitions, cgroup v2 isolation, socket
activation, and full compatibility shims for OpenRC, Runit, and
systemd.

## Design

Litin is structured in three layers:

```
litin-init   (PID 1 bootstrap — pure Crystal)
    |
litind       (supervisor daemon — dependency graph, cgroups, sockets,
    |         timers, IPC server, log streaming)
    |
litinctl     (control tool — humans and scripts)
```

Service definitions are POSIX shell scripts. The static metadata fields
(`name`, `command`, `user`, `type`, `restart`, `cgroup_*`, `depend()`)
are parsed by Litin's built-in parser. Hook functions (`pre_start`,
`post_stop`, `reload`, `healthcheck`) are exec'd via `/bin/sh` at
runtime, so they have the full shell available.

## Building

```sh
# Install Crystal >= 1.10.0 then:
make
make install PREFIX=/usr/local
```

Produces binaries:
- `litin-init` — PID 1 bootstrap
- `litind`     — supervisor daemon
- `litinctl`   — control tool
- `rc-service`, `rc-update`, `rc-status` — OpenRC shims
- `systemctl`  — systemd shim
- `sv`, `runsvdir`, `chpst` — Runit shims

```sh
# Debug build (no optimisation):
make debug

# Run the test suite:
make spec
```

## Quick start (in a container or VM)

```sh
# Point the kernel at litin-init:
# In /etc/inittab, grub, or container entrypoint:
#   /usr/local/sbin/litin-init

# Place a service definition:
mkdir -p /etc/litin/services/nginx
cat > /etc/litin/services/nginx/service.sh <<'EOF'
name="nginx"
command="/usr/sbin/nginx -g 'daemon off;'"
type="simple"
restart="on-failure"
target="default"
depend() { require network; }
EOF

# Enable and start:
litinctl enable nginx
litinctl start nginx
litinctl status nginx
litinctl logs nginx --follow
```

## Service definition reference

```sh
#!/bin/sh

# --- Identity ---
name="myservice"
description="My service"

# --- Execution ---
command="/usr/bin/myservice --foreground"
user="myuser"
group="mygroup"
working_dir="/var/lib/myservice"
type="simple"          # simple | forking | oneshot | notify | socket-activated
pid_file="/run/myservice.pid"   # required for type=forking

# --- Restart ---
restart="on-failure"   # no | on-failure | always | unless-stopped
restart_sec="5"
timeout_start="90"
timeout_stop="30"

# --- Resource limits (cgroup v2) ---
cgroup_memory_max="256M"
cgroup_pids_max="128"
cgroup_cpu_max="50000 100000"

# --- Target membership ---
target="default"

# --- Dependencies ---
depend() {
  require network localfs   # hard: must be ready first
  want logger               # soft: start if available
  after firewall            # ordering only
  before backup             # we start before backup
  conflicts dropbear        # mutual exclusion
}

# --- Hooks (exec'd via /bin/sh, $MAINPID is set) ---
pre_start()   { mkdir -p /run/myservice; }
post_start()  { :; }
pre_stop()    { :; }
post_stop()   { rm -f /run/myservice.pid; }
reload()      { kill -HUP "$MAINPID"; }
healthcheck() { kill -0 "$MAINPID"; }
```

## litinctl reference

```
litinctl start   <service...>
litinctl stop    <service...>
litinctl restart <service...>
litinctl reload  <service...>
litinctl status  [service...] [--json]
litinctl list    [--json]
litinctl list-targets

litinctl enable  <service...> [--target=default]
litinctl disable <service...>
litinctl mask    <service...>
litinctl unmask  <service...>

litinctl logs    <service> [--follow] [--lines=50] [--since=1h]
litinctl deps    <service>
litinctl graph   [service]  # DOT output, pipe to graphviz

litinctl reload-daemon
litinctl shutdown [--mode=halt|reboot|poweroff]
litinctl reboot
litinctl poweroff
```

## Directory layout

```
/etc/litin/
  litin.conf          global configuration
  services/           service definitions (directories or .sh files)
  targets/            target definitions (.target files)
    default.wants/    symlinks to enabled services
  sockets/            socket unit files (.socket)
  timers/             timer unit files (.timer)
  env/                global environment directory (runit-compatible)
  masks/              masked service markers

/run/litin/
  litind.sock         IPC control socket
  notify/             sd_notify sockets (type=notify services)

/var/log/litin/
  <service>.log       per-service timestamped log files

/sys/fs/cgroup/litin/
  <service>/          per-service cgroup v2 slice
```

## Compatibility

See [MIGRATING.md](MIGRATING.md) for a full migration guide from
OpenRC, Runit, Dinit, and systemd.

## License

MIT

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/OkaVatti/litin/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [OkaVatti](https://github.com/OkaVatti) - creator and maintainer
