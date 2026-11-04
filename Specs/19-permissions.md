We want the container to be reliably initially set up with bypass permissions. A couple of scenarios

1. If first-run copies existing set up for claude or opencode v2, then after modifying it should edit the settings so that
	- claude has permissions = bypassPermissions
	- opencode v2 has the equivalent

2. If first-run does not copy existing set up for claude or opencode v2, then it should create the settings to achieve that.

In XS for claude we already set dangerously skip permissions.

3. In XS, for opencode v2, use the --auto flag in go.sh