## How to Install

The installer file:  ``install.sh`` will source and download the extension, and place the files where they need to be on your system correctly.  You can run the following commands:

```
git clone https://github.com/loopyd/install-grass.git
cd install-grass
chmod +x ./install.sh
sudo ./install.sh
```

On some distrobutions, installation of additional packages will be required.  The installer will prompt you which to search your package manager for, and install **manually**.  The names of the packages **may vary** based upon your distrobution.  You can access your package maintainer's resources to locate and install the nessecary packages.

## How to Update

> ⚠️ The ``install-grass`` utility runs as the root user.  This means that permissions for manually installed files are owned by the root (UID=0, GID=0) user.  You will see the message "Update failed" in your Desktop Node when using ``install-grass``.  This is normal.  Extraction with ``ar`` via ``binutils`` is not able to preserve original ACLs, which is why this happens.

To update your node, close your Desktop Node by right-clicking and selecting "Quit" from your Window Manager's taskbar, then open a terminal and type:

```
sudo grass
```

Take the update when prompted.  When completed, close the Desktop Node in the same way again, and then open it from the Applications menu.  Your Grass Desktop Node will be on its most recent version!

## Help!  I have some Grass-GIS thing, what do I do?

This is common on Ubuntu or Debian systems, as there's a conflicting project called grass that gets installed to a new version when your system gets updated.  On these systems, if you use **aptitude**, you can block the arbitrary and unassociated project with a **deprioritization pin**.

> 🌱 These instructions will differ for other package managers.  Please consult your package manager's documentation if you experience this conflict.  Searching its man pages for "blacklist" can help!

```sh
sudo apt-get remove grass* -y
echo "\nPackage: grass*\nPin: release c=universe\nPin-Priority: -100\n" | sudo tee -a /etc/apt/preferences.d/99-priority
```

Once you've done this, you'll need to run ``install-grass`` again.

```
./install.sh
```

Now when your system updates again, this shouldn't happen.
