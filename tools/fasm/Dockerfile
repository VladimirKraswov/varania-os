# Официальный FASM 1.73.35 (linux/amd64) в минимальном образе.
#
# FASM для macOS официально не публикуется (только fasmg — несовместимый
# движок), поэтому сборка исходников проекта выполняется в этом контейнере.
# Бинарник — статический ELF, внешних зависимостей не требует.
FROM debian:bookworm-slim

# Распаковываем официальный архив и ставим fasm в PATH.
COPY fasm-1.73.35.tgz /tmp/fasm.tgz
RUN mkdir -p /opt/fasm \
    && tar -xzf /tmp/fasm.tgz -C /opt/fasm --strip-components=1 \
    && install -m 0755 /opt/fasm/fasm /usr/local/bin/fasm \
    && rm -f /tmp/fasm.tgz

# Рабочая папка примонтированного проекта.
WORKDIR /os
CMD ["fasm"]
