# Remind interactive shells when the image's Flatpak setup has pending
# changes. Local file reads only: no root, no network.
case $- in
    *i*)
        if [ -x /usr/bin/sync-flatpaks ] && /usr/bin/sync-flatpaks --check; then
            printf '\nFlatpak apps for this image are not fully installed (or the list changed).\nRun: sync-flatpaks\n\n'
        fi
        ;;
esac
