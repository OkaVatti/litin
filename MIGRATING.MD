# Migrating to Litin

This document covers how to migrate existing service definitions and
administration habits from OpenRC, Runit, Dinit, and systemd to Litin.
Litin ships shim binaries for the most common tools so that most
existing scripts continue to work without modification.

---

## Compatibility shims installed by Litin

| Binary       | Emulates          | Notes                                    |
| ------------ | ----------------- | ---------------------------------------- |
| `rc-service` | OpenRC            | Full action mapping                      |
| `rc-update`  | OpenRC            | add/del/show with runlevel mapping       |
| `rc-status`  | OpenRC            | Status output                            |
| `systemctl`  | systemd           | Common lifecycle + is-active/is-enabled  |
| `sv`         | Runit             | up/down/restart/reload/status/check      |
| `runsvdir`   | Runit             | Loads a service directory and starts all |
| `chpst`      | Runit/daemontools | Credential dropping + env dir + exec     |

---

## From OpenRC

### Service definition

OpenRC `/etc/init.d/sshd`:

```sh
#!/sbin/openrc-run
name="sshd"
command="/usr/sbin/sshd"
command_args="-D"
pidfile="/run/sshd.pid"
depend() {
  need net
  use logger
}
```

Litin `/etc/litin/services/sshd/service.sh`:

```sh
#!/bin/sh
name="sshd"
command="/usr/sbin/sshd -D -e"
type="simple"
restart="on-failure"
depend() {
  require network
  want logger
}
```

Key differences:

- `need` becomes `require`; `use` becomes `want`
- `command_args` is folded into `command`
- No `command_background`; use `type="forking"` and `pid_file=` instead
- `start_pre()` becomes `pre_start()`, `start_post()` becomes `post_start()`

### Administration

| OpenRC                       | Litin                   |
| ---------------------------- | ----------------------- |
| `rc-service sshd start`      | `litinctl start sshd`   |
| `rc-service sshd status`     | `litinctl status sshd`  |
| `rc-update add sshd default` | `litinctl enable sshd`  |
| `rc-update del sshd default` | `litinctl disable sshd` |
| `rc-status`                  | `litinctl status`       |

---

## From Runit

### Service directory

Runit `/etc/sv/nginx/run`:

```sh
#!/bin/sh
exec nginx -g 'daemon off;'
```

This works in Litin unchanged: place the directory at
`/etc/litin/services/nginx/` and Litin will detect the `run` script.

To add richer metadata, add a `service.sh` alongside `run`:

```sh
name="nginx"
description="Nginx web server"
type="simple"
restart="on-failure"
depend() {
  require network
}
```

### Administration

| Runit                   | Litin                          |
| ----------------------- | ------------------------------ |
| `sv up nginx`           | `litinctl start nginx`         |
| `sv down nginx`         | `litinctl stop nginx`          |
| `sv restart nginx`      | `litinctl restart nginx`       |
| `sv status nginx`       | `litinctl status nginx`        |
| `sv check nginx`        | `litinctl status nginx`        |
| `runsvdir /etc/sv`      | `litinctl start --all`         |
| `chpst -u www-data cmd` | `chpst -u www-data cmd` (shim) |

---

## From Dinit

### Service definition

Dinit `/etc/dinit.d/sshd`:

```
type = process
command = /usr/sbin/sshd -D
logfile = /var/log/sshd.log
depends-on = network
```

Litin equivalent:

```sh
name="sshd"
command="/usr/sbin/sshd -D"
type="simple"
restart="on-failure"
depend() {
  require network
}
```

Dinit `depends-on` → Litin `require`
Dinit `depends-ms` → Litin `want`
Dinit `before` → Litin `before`
Dinit `waits-for` → Litin `after`

### Administration

| Dinit                  | Litin                  |
| ---------------------- | ---------------------- |
| `dinitctl start sshd`  | `litinctl start sshd`  |
| `dinitctl stop sshd`   | `litinctl stop sshd`   |
| `dinitctl status`      | `litinctl status`      |
| `dinitctl enable sshd` | `litinctl enable sshd` |
| `dinitctl list`        | `litinctl list`        |

---

## From systemd

### Unit file

systemd `/etc/systemd/system/nginx.service`:

```ini
[Unit]
Description=Nginx web server
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -g 'daemon off;'
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
User=nginx
Group=nginx
MemoryMax=256M

[Install]
WantedBy=multi-user.target
```

Litin `/etc/litin/services/nginx/service.sh`:

```sh
name="nginx"
description="Nginx web server"
command="/usr/sbin/nginx -g 'daemon off;'"
type="simple"
restart="on-failure"
user="nginx"
group="nginx"
cgroup_memory_max="256M"
target="default"

depend() {
  after network
}

reload() {
  kill -HUP "$MAINPID"
}
```

Key mappings:

- `After=` → `after` in `depend()`
- `Requires=` → `require` in `depend()`
- `Wants=` → `want` in `depend()`
- `ExecReload=` → `reload()` hook
- `MemoryMax=` → `cgroup_memory_max`
- `WantedBy=` → `target` field + `litinctl enable`
- `ExecStartPre=` → `pre_start()` hook
- `ExecStartPost=` → `post_start()` hook
- `ExecStopPost=` → `post_stop()` hook

### Administration

| systemd                          | Litin                               |
| -------------------------------- | ----------------------------------- |
| `systemctl start nginx`          | `litinctl start nginx`              |
| `systemctl stop nginx`           | `litinctl stop nginx`               |
| `systemctl restart nginx`        | `litinctl restart nginx`            |
| `systemctl reload nginx`         | `litinctl reload nginx`             |
| `systemctl status nginx`         | `litinctl status nginx`             |
| `systemctl enable nginx`         | `litinctl enable nginx`             |
| `systemctl disable nginx`        | `litinctl disable nginx`            |
| `systemctl mask nginx`           | `litinctl mask nginx`               |
| `systemctl daemon-reload`        | `litinctl reload-daemon`            |
| `journalctl -u nginx -f`         | `litinctl logs nginx --follow`      |
| `journalctl -u nginx -n 100`     | `litinctl logs nginx --lines=100`   |
| `journalctl -u nginx --since=1h` | `litinctl logs nginx --since=1h`    |
| `systemctl is-active nginx`      | `litinctl status nginx` (exit code) |
| `systemctl reboot`               | `litinctl reboot`                   |
| `systemctl poweroff`             | `litinctl poweroff`                 |

---

## Environment variables injected by Litin

These are available in all hook functions and in the service process:

| Variable         | Value                                        |
| ---------------- | -------------------------------------------- |
| `MAINPID`        | PID of the main service process              |
| `NOTIFY_SOCKET`  | Path to the sd_notify socket (type=notify)   |
| `LITIN_CGROUP`   | Path to the service's cgroup directory       |
| `LISTEN_FDS`     | Number of socket FDs (socket-activated only) |
| `LISTEN_PID`     | PID receiving the FDs                        |
| `LISTEN_FDNAMES` | Colon-separated socket unit names            |
