#!/usr/bin/env python3
"""Отдельно проверить user procd, nameserver и передачу endpoint capability."""

from qemu_testlib import boot_until


def main() -> None:
    output = boot_until(
        (
            b"procd: init started; process service ready",
            b"nameserver: service endpoint registered",
            b"client: service found; four messages sent",
            b"VARANIA:IPC_QUEUE_OK",
        ),
        timeout=10,
    )
    print(output.decode("utf-8", errors="replace"), end="")
    print(
        "Capability/IPC-тест пройден: ELF загружен в user space, "
        "endpoint передан через nameserver и очередь доставила сообщения."
    )


if __name__ == "__main__":
    main()
