# Run on ad01
New-Item -ItemType Directory -Path 'C:\PKITransfer' -Force
New-SmbShare -Name 'PKITransfer' -Path 'C:\PKITransfer' `
    -FullAccess 'ADLAB\Domain Admins' `
    -Description 'PKI certificate exchange'
