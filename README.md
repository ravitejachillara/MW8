# 🚀 MW8 Stack Installer

A no-nonsense VPS autoconfig script to help you spin up:

- **Mautic** for email marketing  
- **WordPress** for landing pages and content  
- **n8n** for powerful automation workflows  
- All routed through **Traefik** with SSL, using Docker containers—no clashes, no drama.

Everything runs isolated, all credentials are dynamically created or set by *you*, and no hardcoded nonsense anywhere.

---

## 🧱 What This Script Does

✔️ Updates your system  
✔️ Installs Docker + Compose  
✔️ Configures firewall (UFW)  
✔️ Sets up Traefik (with ACME SSL)  
✔️ Deploys apps with optional choices  
✔️ Assigns subdomains per app (Mautic, WordPress, n8n)  
✔️ Logs and checks for: DNS, database, SSL, port & routing issues  
✔️ Saves credentials securely on the server  
✔️ Health checks and output of URLs and access details at the end

---

## 📦 Install Requirements

- Ubuntu 20.04 or higher  
- A VPS (DigitalOcean, Hetzner, etc.)  
- Root or sudo access  
- Subdomains ready and pointing to your server IP

---

## ⚙️ How to Use

1. **SSH into your server**

   ```bash
   ssh root@your-server-ip
   ```

2. **Run the install script via cURL**

   ```bash
   curl -s https://raw.githubusercontent.com/yourusername/mw8-stack/main/mw8-install.sh | bash
   ```

   > _Or clone and run manually:_

   ```bash
   git clone https://github.com/yourusername/mw8-stack.git
   cd mw8-stack
   chmod +x mw8-install.sh
   ./mw8-install.sh
   ```

---

## 🤖 What You’ll Be Asked

- Which apps to install:  
  a) Mautic  
  b) WordPress  
  c) n8n  
  d) Any combo of the above

- Your email (for SSL certs)  
- Subdomains for each selected app  
- Admin usernames and passwords (or generate randomly)  

---

## 🔍 After Setup

1. Access each app using its subdomain:
   - Mautic: `https://mautic.yourdomain.com`
   - WordPress: `https://wp.yourdomain.com`
   - n8n: `https://n8n.yourdomain.com`

2. Visit Traefik dashboard:  
   `https://traefik.yourdomain.com`

3. Check log file + credentials file saved at:  
   `/root/mw8-stack/mw8-credentials.txt`

---

## ⚠️ Troubleshooting Tips

- Make sure DNS is pointing to your server before running the script  
- Allow ports 80, 443, and optionally 8080 (Traefik UI)  
- If something feels stuck, check:
  - `docker ps` for running containers  
  - `docker-compose logs` for any weird errors  
  - Traefik dashboard for SSL/routing status

---

## 📌 Coming Soon

- Add Mail server setup (Postfix or SendGrid integration)  
- Enable autoscaling with Docker Swarm  
- CLI dashboard for managing all apps in one place  

---

## 👨‍💻 Maintained by

**Ravi Teja Chillara**  
Bringing you simplified server stacks, minus the chaos.  
[ratechi.com](https://ratechi.com)
