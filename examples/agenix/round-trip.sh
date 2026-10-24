# Encrypt a secret with agenix to a fresh age key, then decrypt it, all in a
# temporary directory.
set -eu
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cd "$dir"
age-keygen -o key.txt 2>/dev/null
printf '{ "moo.age".publicKeys = [ "%s" ]; }\n' "$(age-keygen -y key.txt)" \
	>agenix-rules.nix
echo "the cow says moo" | agenix -e moo.age
agenix -d moo.age -i key.txt
