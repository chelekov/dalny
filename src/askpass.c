#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void wipe(void* buffer, size_t length)
{
	volatile unsigned char* bytes = buffer;
	while (length > 0)
		bytes[--length] = 0;
}

/* Prints the SSH secret from a 0600 file. Invoked by ssh via SSH_ASKPASS. */
int main(void)
{
	const char* path = getenv("DALNY_ASKPASS_FILE");
	if (!path || !path[0])
		return 1;

	FILE* file = fopen(path, "r");
	if (!file)
		return 1;

	char buffer[8192];
	size_t length = fread(buffer, 1, sizeof(buffer) - 1, file);
	fclose(file);
	buffer[length] = '\0';
	while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r'))
		buffer[--length] = '\0';

	fwrite(buffer, 1, length, stdout);
	fputc('\n', stdout);
	fflush(stdout);
	wipe(buffer, sizeof(buffer));
	return 0;
}
