#!/usr/bin/env bash
# Affiche une clé aléatoire de 32 octets, encodée en base64, pour une EncryptionConfiguration.
head -c 32 /dev/urandom | base64
