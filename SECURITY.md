# Operator key management

The take-home host runs a public PreProd archive node for the onboarding simulation. Production validator keys would have their own signing and governance lifecycle.

## Storage

- **Separate keys by purpose and network.** Keep governance and recovery keys offline with two-person access. Give the validator runtime access only to its online consensus keys. Maintain an inventory of key purpose, public fingerprint, registered operator, signer, custodians, and activation status. Keep operator keys off the RPC and indexer hosts.
- **Use a remote signer where the node and algorithm support it.** Generate non-exportable keys in an HSM or KMS and restrict the runtime identity to signing with the specific keys. Validate signature format, latency, failover, and audit logging in PreProd. Midnight documents Sr25519 for AURA, Ed25519 for GRANDPA, and ECDSA for partner-chain messages and BEEFY. AWS KMS supports Ed25519 and secp256k1, so the complete key set needs a signer plan that also covers Sr25519. CloudHSM gives the team more control over custody and redundancy and adds cluster cost and operations. [Midnight signature schemes](https://docs.midnight.network/nodes#signature-schemes) · [AWS KMS algorithms](https://docs.aws.amazon.com/kms/latest/developerguide/kms-cryptography.html) · [CloudHSM signing](https://docs.aws.amazon.com/cloudhsm/latest/userguide/key_mgmt_util-sign.html)
- **Use Secrets Manager for secrets the process must read.** A supported file-based keystore needs a dedicated service identity, a restricted secret reference, and a protected key file on an isolated signer. The plaintext is available to the signing process, so host access and crash dumps matter. Keep PostgreSQL credentials and validator keys in distinct secrets and exclude secret values from Git, Terraform state, user data, and logs. Audit reads and signing operations. Test recovery with custodians and exercise signer failover with a single active signer. [Secrets Manager encryption](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html)

## Rotation

1. Confirm the change process and effective session or governance boundary with the network operator. Generate the replacement key in its target signer and verify its public fingerprint with a second operator. Rehearse the cutover and downtime budget in PreProd.
2. Submit the new public key through the applicable registration process. Verify the accepted key and activation boundary from the chain. Prepare a synced standby and move signing at that boundary with one active signer. Monitor authorship, finality, peer count, and signer errors during the cutover.
3. Confirm the new key is active and the old authorization is gone. Remove the old signer grant and retire the old key under the retention policy. A rollback must respect the active on-chain registration. Record the transaction, activation height, observed signing checks, and custodian approvals.

## Suspected compromise

1. **Contain signing.** Pause the affected validator or revoke its signer access, isolate the suspected host, and alert the incident lead and Midnight operator contacts. Record the affected public keys, network, and last known good height.
2. **Preserve evidence and establish scope.** Preserve signing, system, access, and audit logs. Compare signer activity with on-chain events and check which other identities or credentials the host could access. Keep suspect material isolated for the incident investigation.
3. **Remove the old authority and recover on clean infrastructure.** Use the emergency governance or deregistration path, generate fresh keys, and rotate exposed infrastructure credentials. Confirm the chain recognizes the replacement and the old keys can no longer authorize signing before resuming participation.
