#!/bin/sh
set -u
case "${1:---plan}" in
  --plan|-h|--help)
    printf '%s\n' 'Usage: ansible_setup.sh [--plan|--audit]' 'Ansible installation is not automated. Review event rules, package source/version and connection credentials first.'
    printf '%s\n' 'https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html'
    exit 0 ;;
  --audit) command -v ansible >/dev/null 2>&1 || { printf '%s\n' 'Ansible unavailable; no coverage' >&2; exit 2; }; ansible --version ;;
  *) printf '%s\n' 'Automatic installation/apply is disabled; use --plan or --audit' >&2; exit 1 ;;
esac
