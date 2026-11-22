# أداة المالك لتوليد كود التفعيل — لا تشاركها مع أحد
# الاستخدام: python3 keygen.py ABCDE-FGHJK
import hmac, hashlib, sys
SECRET = "e13cdf58299ff9ecdd661192d9576d4651147eef728b7dd3"  # يجب أن يطابق licSecret في lib/license.dart
def code(i):
    h = hmac.new(SECRET.encode(), i.strip().upper().encode(), hashlib.sha256).hexdigest().upper()[:16]
    return "-".join(h[k:k+4] for k in range(0, 16, 4))
for dev in sys.argv[1:] or [input("رقم الجهاز: ")]:
    print(dev, "=>", code(dev))
