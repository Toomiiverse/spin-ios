# spin-sources

Search (ytmusicapi, SoundCloud) and SoundCloud downloads (scdl) for Spin. Runs on haruserver:

    uv venv ~/spin-sources/venv && uv pip install --python ~/spin-sources/venv/bin/python ytmusicapi scdl
    cp server/spin-sources.service ~/.config/systemd/user/ && systemctl --user enable --now spin-sources
    tailscale serve --bg --https=8930 --set-path=/sources http://127.0.0.1:8011

`python server/spin-sources.py selftest` checks the link and folder-name guards.
