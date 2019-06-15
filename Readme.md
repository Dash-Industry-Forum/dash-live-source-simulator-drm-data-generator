# DRM data generator for the DASH-IF live source simulator

This script generates DRM data for use with the live source simulator. For more details on what it does, see inline comments. The output is a CPIX file describing the data to be used.

# Usage

Run the script and answer any prompts.

The output will be:

* Some useful data in console for human-readable consumption.
* A CPIX file DrmData.xml describing what a packager must do with the content to apply the generated data.
* A set of `<keyid>.token.txt` files with Axinom DRM license tokens ready to be pasted into the [DASH-IF test vectors authorization token provider](https://github.com/Dash-Industry-Forum/test-vectors-drm-authz-token-provider).
* An `AllKeys.token.txt` file with an Axinom DRM license token that authorizes all the keys, for easy manual testing.

Add the `-Verbose` parameter to see intermediate data dumps.