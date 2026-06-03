#!/bin/bash
# DevOps Project Prerequisites Installation Guide for WSL2
# This script installs: kubectl, Helm, Python 3, psql, mongosh
# Already installed: AWS CLI, Docker

set -e  # Exit on any error

echo "=========================================="
echo "DevOps Project Prerequisites Installation"
echo "WSL2 Ubuntu Setup"
echo "=========================================="
echo ""

# ═══════════════════════════════════════════════════════════════
# 1. UPDATE PACKAGE MANAGER
# ═══════════════════════════════════════════════════════════════
echo "[1/6] Updating package manager..."
sudo apt-get update
echo "✓ Package manager updated"
echo ""

# ═══════════════════════════════════════════════════════════════
# 2. INSTALL KUBECTL
# ═══════════════════════════════════════════════════════════════
echo "[2/6] Installing kubectl..."
echo "  → Downloading kubectl binary"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
echo "  → Making executable"
chmod +x kubectl
echo "  → Installing to /usr/local/bin"
sudo mv kubectl /usr/local/bin/kubectl
echo "  → Verifying installation"
kubectl version --client
echo "✓ kubectl installed successfully"
echo ""

# ═══════════════════════════════════════════════════════════════
# 3. INSTALL HELM
# ═══════════════════════════════════════════════════════════════
echo "[3/6] Installing Helm..."
echo "  → Downloading Helm installation script"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "  → Verifying installation"
helm version
echo "✓ Helm installed successfully"
echo ""

# ═══════════════════════════════════════════════════════════════
# 4. INSTALL PYTHON 3
# ═══════════════════════════════════════════════════════════════
echo "[4/6] Installing Python 3..."
echo "  → Installing python3 and pip"
sudo apt-get install -y python3 python3-pip python3-venv
echo "  → Verifying Python installation"
python3 --version
echo "  → Verifying pip installation"
pip3 --version
echo "✓ Python 3 installed successfully"
echo ""

# ═══════════════════════════════════════════════════════════════
# 5. INSTALL POSTGRESQL CLIENT (psql)
# ═══════════════════════════════════════════════════════════════
echo "[5/6] Installing PostgreSQL client (psql)..."
echo "  → Installing postgresql-client"
sudo apt-get install -y postgresql-client
echo "  → Verifying installation"
psql --version
echo "✓ PostgreSQL client installed successfully"
echo ""

# ═══════════════════════════════════════════════════════════════
# 6. INSTALL MONGODB CLIENT (mongosh)
# ═══════════════════════════════════════════════════════════════
echo "[6/6] Installing MongoDB client (mongosh)..."
echo "  → Adding MongoDB repository"
curl https://www.mongodb.org/static/pgp/server-7.0.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
echo "  → Updating package manager"
sudo apt-get update
echo "  → Installing mongosh"
sudo apt-get install -y mongosh
echo "  → Verifying installation"
mongosh --version
echo "✓ MongoDB client installed successfully"
echo ""

# ═══════════════════════════════════════════════════════════════
# FINAL VERIFICATION
# ═══════════════════════════════════════════════════════════════
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Verification of all tools:"
echo ""
echo "kubectl:"
kubectl version --client --short
echo ""
echo "Helm:"
helm version --short
echo ""
echo "Python:"
python3 --version
echo ""
echo "pip:"
pip3 --version
echo ""
echo "psql (PostgreSQL client):"
psql --version
echo ""
echo "mongosh (MongoDB client):"
mongosh --version
echo ""
echo "✓ All prerequisites installed successfully!"
echo ""
echo "Next steps:"
echo "1. Clone the repository:"
echo "   git clone https://github.com/N4si/K8s-video-converter.git"
echo "   cd K8s-video-converter"
echo ""
echo "2. Verify AWS CLI:"
echo "   aws --version"
echo ""
echo "3. Verify Docker:"
echo "   docker --version"
echo ""
echo "4. Configure AWS credentials (if not already done):"
echo "   aws configure"
echo ""
