#!/bin/bash
verify_version() {
  RUN_NUM=$1
  OFFSET=0
  COUNTER=$((RUN_NUM - 1 + OFFSET))
  MAJOR=1
  MINOR=$((COUNTER / 30))
  PATCH=$((COUNTER % 30))
  echo "Run $RUN_NUM: v${MAJOR}.${MINOR}.${PATCH}"
}

verify_version 1
verify_version 30
verify_version 31
