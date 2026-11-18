"""Creates the IAM users ceph/s3-tests needs on a fresh Zee3 node and writes
its config file.

usage: setup_users.py <admin-url> <s3-host> <s3-port> <root-access> <root-secret> <out.conf>

The main user is the root account. alt and tenant are IAM users without
policies: like another AWS account, they reach main's buckets only through
bucket policies (Zee3 has one account and no bucket owners, so tests that need
alt to own buckets are excluded, see s3tests-exclude.txt). The KMS keys
testkey-1 and testkey-2 back the SSE-KMS tests.
"""
import json
import sys
import time
import urllib.error
import urllib.request

admin, host, port, root_ak, root_sk, out = sys.argv[1:7]


def call(path, body=None, token=None, method="POST"):
    req = urllib.request.Request(admin + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"content-type": "application/json"})
    if token:
        req.add_header("authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=10) as r:
        data = r.read()
        return json.loads(data) if data else None


for _ in range(60):
    try:
        call("/api/health", method="GET")
        break
    except Exception:
        time.sleep(1)
token = call("/api/auth/login", {"access_key": root_ak, "secret_key": root_sk})["token"]
users = {
    "alt": ("s3testsalt", "s3tests-alt-secret-0123456789"),
    "tenant": ("s3teststenant", "s3tests-tenant-secret-0123456789"),
}
for name, secret in users.values():
    try:
        call("/api/iam/users", {"name": name, "secret_key": secret, "policies": []}, token)
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise
for key in ("testkey-1", "testkey-2"):
    try:
        call("/api/kms/keys", {"name": key, "description": "ceph/s3-tests"}, token)
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise

conf = f"""[DEFAULT]
host = {host}
port = {port}
is_secure = False
ssl_verify = False

[fixtures]
bucket prefix = s3t-{{random}}-
iam name prefix = s3-tests-
iam path prefix = /s3-tests/

[s3 main]
display_name = root
user_id = {root_ak}
email = main@example.com
api_name =
kms_keyid = testkey-1
kms_keyid2 = testkey-2
access_key = {root_ak}
secret_key = {root_sk}

[s3 alt]
display_name = alt
user_id = {users['alt'][0]}
email = alt@example.com
access_key = {users['alt'][0]}
secret_key = {users['alt'][1]}

[s3 tenant]
display_name = tenant
user_id = {users['tenant'][0]}
email = tenant@example.com
access_key = {users['tenant'][0]}
secret_key = {users['tenant'][1]}
tenant = testx

[iam]
email = s3@example.com
user_id = {root_ak}
access_key = {root_ak}
secret_key = {root_sk}
display_name = root

[iam root]
access_key = {root_ak}
secret_key = {root_sk}
account_id = {root_ak}
user_id = {root_ak}
email = account1@example.com

[iam alt root]
access_key = {users['alt'][0]}
secret_key = {users['alt'][1]}
account_id = {users['alt'][0]}
user_id = {users['alt'][0]}
email = account2@example.com
"""
with open(out, "w") as f:
    f.write(conf)
print(f"wrote {out}")
