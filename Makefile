.PHONY: verify switch-site-a switch-site-b cleanup

verify:
	./verify.sh

switch-site-a:
	./scripts/switch-frontend.sh site-a

switch-site-b:
	./scripts/switch-frontend.sh site-b

cleanup:
	./cleanup.sh
