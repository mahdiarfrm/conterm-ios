# The root filesystem the phone's Debian boots, with a working set of GNU
# and shell tools baked in, so the machine is useful the moment it boots
# and before it has a network. Everything here is on disk in the image;
# `apt-get install` still works at runtime for anything else, though what
# it installs is lost at power off.
#
# Trim or extend the list to change the image's size. Each package is
# uncompressed into the rootfs and packed into the wasm the app ships.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      bash bash-completion \
      coreutils findutils grep sed gawk diffutils patch \
      curl wget git \
      nano vim-tiny less tree file \
      procps iproute2 \
      jq bsdextrautils \
      unzip zip gzip bzip2 xz-utils tar \
      python3 \
      ncurses-bin ncurses-term locales \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* \
    && ln -sf /usr/bin/vim.tiny /usr/local/bin/vim

# A prompt and a couple of habits, so the shell feels lived-in.
RUN printf '%s\n' \
      "alias ll='ls -alF'" \
      "alias la='ls -A'" \
      "alias l='ls -CF'" \
      "export PS1='\\[\\e[1;36m\\]\\u@debian\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\\$ '" \
      "[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion" \
      > /root/.bashrc

CMD ["/bin/bash"]
