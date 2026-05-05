#!/bin/sh
set -e

# Start litind in the background (not as PID 1) if we need to run tests.
# For a true init system, you would replace the container's init with litin_init,
# but that requires kernel capabilities. For testing purposes, we run litind as a
# daemon and then execute the tests.
#
# In a full Koi Linux scenario, litin_init would be the real PID 1.

# Create required directories
mkdir -p /run/litin/notify /var/log/litin /tmp/litin-run

# Start litind
/usr/local/sbin/litind &
LITIND_PID=$!

# Wait for the socket
while [ ! -S /run/litin/litind.sock ]; do
  sleep 0.1
done

# Run the test suite
cd /litin  # assuming the source is mounted or copied
crystal spec ./spec --order random
TEST_EXIT=$?

# Signal litind to stop
kill $LITIND_PID
wait $LITIND_PID 2>/dev/null

exit $TEST_EXIT