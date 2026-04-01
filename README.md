# 🛡️ Enterprise Post-Migration Health Check & Audit Tool

สคริปต์สำหรับการตรวจสอบสุขภาพระบบ (Health Check) และตรวจสอบความปลอดภัย (Security Audit) หลังการย้ายระบบ (Migration) หรือการรับดูแลเซิร์ฟเวอร์ใหม่แบบ **Blind Audit** ออกแบบมาเพื่อช่วยให้ System Engineer ทำงานได้เร็วขึ้นและแม่นยำขึ้น

## 🌟 จุดเด่น (Key Features)

* **Universal Compatibility:** รองรับ OS ตระกูลหลักทั้ง Debian (Ubuntu, Debian) และ RHEL (CentOS, RHEL, Rocky, AlmaLinux)
* **Deep Application Discovery:** ค้นหาแอปพลิเคชันและเซอร์วิสที่ซ่อนอยู่โดยอัตโนมัติ (Zimbra, Control Panels, Docker, PM2 และ Enterprise Apps อื่นๆ)
* **Safe Execution:** รองรับทั้งระบบใหม่ (systemd) และระบบเก่า (SysVinit/LXC) โดยไม่มี Error กวนใจ
* **Security Insight:** ตรวจสอบการโจมตี Brute Force และการฝัง SSH Key ของบุคคลภายนอก
* **One-Liner Execution:** สามารถรันผ่าน URL ได้ทันทีโดยไม่ต้องดาวน์โหลดไฟล์ลงเครื่องก่อน

---

## 🛠️ รายการตรวจสอบ (Audit Modules)

1. **System Resources:** ตรวจสอบ Load Average, Kernel, และเวลาของระบบ
2. **Storage Integrity:** เช็ค Disk Space, Inode และตรวจสอบว่าพาร์ทิชันใน `fstab` ถูกเมาท์ครบถ้วนหรือไม่
3. **Network & Connectivity:** ทดสอบการออกอินเทอร์เน็ตทั้งผ่าน IP และการทำ DNS Resolution
4. **Service Health:** ตรวจสอบสถานะการทำงานของ Core Services (Web, DB, SSH)
5. **Blind Audit (App Discovery):**
   * สแกนหา Enterprise Suites (Zimbra, cPanel, GitLab)
   * ค้นหาโปรเซสที่รันภายใต้ User พิเศษ (เช่น postgres, prometheus)
   * กวาดหาแอปที่ติดตั้งไว้ในโฟลเดอร์ `/opt`
   * ตรวจสอบ Docker Containers และสถานะโปรเซสใน PM2
6. **Advanced Security:**
   * ตรวจสอบสิทธิการเข้าถึงของ User และ Admin
   * เช็ครายการ Authorized SSH Keys
   * ตรวจจับการพยายามล็อกอินผิดพลาด (Brute Force Detection) พร้อมสรุปเป้าหมายการโจมตี
   * สแกนหาไฟล์สคริปต์ที่น่าสงสัยในไดเรกทอรีชั่วคราว (`/tmp`)

---

## 🚀 วิธีใช้งาน (How to Use)

### 1. รันผ่าน One-Liner (แนะนำ)
สามารถสั่งรันได้ทันทีจากเซิร์ฟเวอร์ปลายทางด้วยคำสั่งเดียว:

**ใช้ `curl` (สำหรับ Ubuntu/Debian):**
รันจาก Git Repository โดยตรง (ไม่ต้อง Clone)
```bash
curl -sL https://raw.githubusercontent.com/Greedtik/Migration-Health-Check/refs/heads/main/health_check-v3.sh | bash

```
```
ใช้ wget (สำหรับ RHEL/CentOS):
wget -qO- https://raw.githubusercontent.com/Greedtik/Migration-Health-Check/refs/heads/main/health_check-v3.sh | sudo bash
```

## รายงานผล (Output & Logs)
Terminal: แสดงผลแยกสี (Color-coded) เพื่อให้ง่ายต่อการอ่านสถานะ [PASS], [WARNING], [FAIL]

Log File: ทุกครั้งที่รัน ระบบจะบันทึกรายงานฉบับเต็มไว้ที่ /var/log/migration_audit_YYYY-MM-DD_HH-MM.log โดยอัตโนมัติ

## **ข้อควรระวัง**
ต้องรันสคริปต์ด้วยสิทธิ root (sudo) เท่านั้น เพื่อให้สามารถเข้าถึงไฟล์คอนฟิกและ Log ระดับลึกของระบบได้

ในส่วนของการตรวจสอบ Zimbra Status สคริปต์มีการตั้ง timeout ไว้เพื่อป้องกันกรณีที่บริการของ Zimbra ตอบสนองช้าจนทำให้การตรวจสอบค้าง


