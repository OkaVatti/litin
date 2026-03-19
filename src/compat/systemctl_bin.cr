require "../compat/systemd"
exit Litin::Compat::Systemd.systemctl(ARGV)
