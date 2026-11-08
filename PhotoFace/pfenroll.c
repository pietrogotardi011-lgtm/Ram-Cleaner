#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <notify.h>
#include <sys/stat.h>

#define DIR "/var/mobile/Library/PhotoFace"

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "clear")) {
        notify_post("com.photoface.clear");
        puts("PhotoFace data cleared.");
        return 0;
    }
    char *pw = getpass("Device passcode (stored in Keychain, used to unlock): ");
    if (!pw || !*pw) { fputs("No passcode given.\n", stderr); return 1; }

    unlink(DIR "/status.txt");
    int fd = open(DIR "/passcode.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { perror("open"); return 1; }
    write(fd, pw, strlen(pw));
    close(fd);
    if (geteuid() == 0) chown(DIR "/passcode.tmp", 501, 501);
    memset(pw, 0, strlen(pw));

    notify_post("com.photoface.enroll");
    puts("Look at the FRONT camera. Slowly turn your head a little left/right/up/down for ~8 seconds...");

    for (int i = 0; i < 60; i++) {
        usleep(500000);
        FILE *f = fopen(DIR "/status.txt", "r");
        if (f) {
            char line[256] = {0};
            fgets(line, sizeof line, f);
            fclose(f);
            printf("%s\n", line);
            return strncmp(line, "ok", 2) ? 1 : 0;
        }
    }
    puts("Timed out waiting for SpringBoard.");
    return 1;
}
