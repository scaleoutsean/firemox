# Firemox utilities

## SolidFire Volume Access Group (VAG)

Firemox prefers CHAP over VAG, but if you want to use VAG, you can reference these scripts to more easily maintain VAG IQN information.

Volumes can be added to the VAG in bulk using Firemox, so there's no equivalent script for that. IQNs can't be added in bulk and pasting them one by one is annoying, hence these scripts. Remember to remove dead PVE nodes' IQNs.

### `get-initiator-names.sh`

This Bash script logs in to selected PVE hosts (it's easier if you have password-less SSH set up), retrieves their IQN and stores the hostname and IQN into a CSV file in current directory.

When you update IQN list, remove existing PVE node names from `hosts` variable because `set-initiators.ps1` uses the API method that creates new initiators (`CreateInitiators`) which doesn't work for updates.

### `set-initiators.ps1`

You may use it to bulk-create IQNs. 

In repeated runs, remove existing IQNs from CSV file. 

Check the source to make sure the VAG ID is right and other options suitable for your environment. The rest of options are pretty generic, but having the righ tVAG ID is critical. 



