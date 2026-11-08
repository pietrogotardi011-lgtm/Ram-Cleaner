# PhotoFace
Build: push to GitHub -> Actions -> download artifact "PhotoFace-deb" (or `make package` with Theos on a Mac).
Install the .deb (Sileo/Filza/dpkg -i), it respring automatically.
Enroll:  `pfenroll`   (run in NewTerm/SSH; asks passcode, then captures your face)
Remove:  `pfenroll clear`
