/// A certificate for `localhost` that nothing trusts, and the key that goes with it.
///
/// Generated once, self-signed, and valid into the next century so that a test never goes red on a
/// date. IT IS NOT A SECRET AND NEVER WAS: it was made for this file, it signs nothing outside this
/// process, and the server it stands up listens on the loopback address on a port the operating
/// system picks. Read it as test data of the same standing as a fixed string.
///
/// WHY A REAL ONE. What is being held here is that a certificate the client cannot verify ends the
/// exchange unless the request said otherwise, and that is a property of the TLS handshake — not of
/// a flag being copied from one object to another. A test that asserted the copying would pass with
/// the check deleted, which is the whole failure this pair exists to make impossible.
library;

/// The certificate the test server presents.
const String selfSignedCertificate = '''
-----BEGIN CERTIFICATE-----
MIIDAzCCAeugAwIBAgIUA76WLLZq1YefMJtFHlX2BbTHKWgwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDgyMzE3NDkwNloYDzIxMjYw
NzMwMTc0OTA2WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDAtu5KrccKCrrhR0KtYbVrxFZ6sNpRvfdsBHxYAmDS
2RM3JcypIiIjtya8Bx3RkdhfErGYtKMhCWATOmZ1RcCw/vvf97hXxNpaotCx+FiM
Q8h4xbNJb+yoPhO1e7TfUc3SyiQ7tVuKAqBitRmXAVSm9ep2sa35cJVn89NKMSGO
GJfWETuZXqBEup5H7sTQchl4a6Sdr4z+VsQzdEZonA7H6+/YaCgNmAUcFKv7XK0W
/cpwKwNYiwABnaP2k/B0FFOkDlubZ4or0SB2nxq7mmVYz+4cv5joV5loqUcT7I/W
robqLtawazNnuSkwlS0PfCp4yhnfzA1gtqUL87keCsKHAgMBAAGjSzBJMBoGA1Ud
EQQTMBGCCWxvY2FsaG9zdIcEfwAAATAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTF
txzeld/ZfGZ7FcH74HBGTb1LnTANBgkqhkiG9w0BAQsFAAOCAQEALeXX552ofYMV
OEAufE56GkJ9O0bpaYUjbgDaame/cw3dRghV/5aO6vDw8dvyA6h2pPJeSxg+iuq3
YenZESGGsM9fCc8RbAPmUpbWUZTG+lV34AzTmFbXhIIgmsiELQfbjLRBJCcr8fjl
Aih9VyBmJAbJK9ILC6siSzTwPnFsTtg029Vv3B6UVCaLhzx40/vsTW6ph1kg5hcW
HhiRFR22jxwb7bD5sQ0zuF99hKnBeUybzIG+/NLkQA6WziFzfL6mJzzaMKKvzvzS
Noa4bpB4Z6VK5T+mC34tth58xNKhaq0jjCDPLXPkDb1P50UGD4kfEsmWZlGwUHgK
VkFKFp2K5A==
-----END CERTIFICATE-----
''';

/// Its private key, which is what lets the server present it at all.
const String selfSignedKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDAtu5KrccKCrrh
R0KtYbVrxFZ6sNpRvfdsBHxYAmDS2RM3JcypIiIjtya8Bx3RkdhfErGYtKMhCWAT
OmZ1RcCw/vvf97hXxNpaotCx+FiMQ8h4xbNJb+yoPhO1e7TfUc3SyiQ7tVuKAqBi
tRmXAVSm9ep2sa35cJVn89NKMSGOGJfWETuZXqBEup5H7sTQchl4a6Sdr4z+VsQz
dEZonA7H6+/YaCgNmAUcFKv7XK0W/cpwKwNYiwABnaP2k/B0FFOkDlubZ4or0SB2
nxq7mmVYz+4cv5joV5loqUcT7I/WrobqLtawazNnuSkwlS0PfCp4yhnfzA1gtqUL
87keCsKHAgMBAAECggEATYEEgsoy00oPcIyNN1elc+rpcLxxgRBqUmnXbDnAoOum
e7ZbAeZ1XnHJRTODfYYvQ8Ur4aM8PAweNH13OVDNNyHFQITLAZlsy6jRT9H2Iqsc
E95GxZEa12rn2EQhMPMgWNbtDYpZfz6hLDFzUjS5y8/49LVup3Ps0nrQDfWGbjOn
c86ZUEbk3qu/G2pzmvtszvq+JJhF/az/hwVadP3UDAdaa9mZXOyWzQ8oWKllY2XJ
uY/yK+vI12UPNEgyBCS3uS7zR5/Arcme6UAME9Y1wAMOp7w+OlC+SrwNC9xVH+7B
3p9mOIrjLPGmb2HD9zPkehGH18ASfe0cYtTbIom+6QKBgQD/KNau+a0lWLQIy0qz
IUlnjd3TSgq4XGBr5/ZhJ5UStVwwltFsLeTLzGpII4KSXml1E9A32eKsoEeJDsKI
pvTO2ZILrWcGnzJLkgw0m3NJDr9wSKbAhjteb/F66ug5K5eMQGJZdbSvFzHkvmCf
im6z+IPmVfp+E2DZvCkFyFOBqwKBgQDBWW+b7q91XtgmNLPaJuhcCCS727JTYBca
qsQEaMdqANTvx4Iwc4xz/VSmuimX5sWQ/m9odGk0YBCfqpWtuuURhUGJH2udJZ+D
sfh425tY9AfISeyENO+180QIa1KOR/tKN5BlzXtb5rqJmdJh3G4jLOjGXSZ58ZUP
bZQdbvrelQKBgQDYW7WmivnBiDSonFDMEbafg1EMP2VVrKbp+LgW66xhP71bShds
JoIyOTQJ1Wp7WGkNqG5PXYbyn7nowsY7f25oE17eXfvVRposMDv/Q6z+zu2PdVtI
NsoSqtNVSej9yTPo7hM3DjLWoNFix/dAcO6r1ldpsZAE5cOi/QS/7Xy5nwKBgQCI
LsY9vlA3CyaTQmurK9xddh7pckSYFQYw8jY+JM7QCuXwPUWler1itPv6swS4yQI+
rfcqS1QOX9tVmoDybMELJiCSxF63wNgpmiC4f3VbogYZPHgqZl6weTdh9rWfIXQN
QjWifqh0gn7AjGdyJiAtBmSt0s5W9aFXzIaWdKSeQQKBgQD2JNR0zqLiyT6XKl+e
c7YvDsKSU1CVeNDtMegobyjyoTLx6/6GFiI/deJvO9TRuRc389eTgA/LlU8aoPK4
queD4sH8Oiolv9YlaZYy8J89d8k38bg9CYkltcgEjYeKLNTqhAHn3HYmH4zFJDHW
rVrSgYQ9RVOS6NXal9BO0tTaGw==
-----END PRIVATE KEY-----
''';
