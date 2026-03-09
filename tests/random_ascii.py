#!/usr/bin/env python3
import random
import sys

count = 0
while True:
    char = chr(random.randint(33, 126))  # printable ASCII excluding space
    sys.stdout.write(char)
    count += 1
    if count % 1000 == 0:
        sys.stdout.write(f'<{count}>')
        sys.stdout.flush()
