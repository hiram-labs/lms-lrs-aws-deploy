#! /bin/sh

set +e

show_help()
{
    cat <<EOF
Usage:
    $0 [OPTIONS] <COMMANDS> [ARGS]

Commands:
    start         Start all services and nginx.
    stop          Stop all services and nginx.
EOF
exit 1
}

log ()
{
  echo "CTL [INFO]: $1"
}

stop ()
{
    nginx -s stop
    pm2 delete all
}

start() {
  (
    cd /app || exit 1

    pm2 start pm2.json
    nginx
    ls /root/.pm2/logs/*.log | xargs tail -n 300 -f
  )
}

if [ "$1" = "stop" ]; then
  stop
elif [ "$1" = "start" ]; then
  start
else
  show_help
fi
