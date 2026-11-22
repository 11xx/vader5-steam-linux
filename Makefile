.PHONY: help install uninstall update-sdl rebuild status enable disable check

help:
	@printf '%s\n' \
		'Targets:' \
		'  install     Build (Sniper SDK) and deploy patched SDL3 into Steam' \
		'  uninstall   Restore stock Steam SDL3 and remove installed files' \
		'  update-sdl  Fetch latest upstream SDL3 main and rebuild' \
		'  rebuild     Force clean CMake configure and rebuild of SDL3' \
		'  status      Show controller firmware and third-party flag state' \
		'  enable      Enable controller third-party mapping firmware flag' \
		'  disable     Disable controller third-party mapping firmware flag' \
		'  check       Lint install/uninstall scripts with bash -n and shellcheck'

install:
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

update-sdl:
	bash scripts/install.sh --update-sdl

rebuild:
	bash scripts/install.sh --rebuild

status:
	python3 tools/vader5-thirdparty.py status

enable:
	python3 tools/vader5-thirdparty.py enable

disable:
	python3 tools/vader5-thirdparty.py disable

check:
	bash -n scripts/install.sh scripts/uninstall.sh && shellcheck scripts/install.sh scripts/uninstall.sh
