#!/bin/sh
# Stand-in for a long GPU job, used by demo.tape.
echo "training $1 model on the GPU..."
for epoch in 1 2 3 4; do
  sleep 1.5
  echo "  epoch $epoch/4"
done
echo "done ✓"
