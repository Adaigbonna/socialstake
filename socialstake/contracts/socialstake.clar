;; Social Stake - Decentralized Social Accountability & Goal Achievement Platform
;; A production-ready smart contract for staking on personal commitments with social verification

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u1200))
(define-constant err-not-found (err u1201))
(define-constant err-unauthorized (err u1202))
(define-constant err-invalid-amount (err u1203))
(define-constant err-commitment-active (err u1204))
(define-constant err-commitment-ended (err u1205))
(define-constant err-already-verified (err u1206))
(define-constant err-cannot-verify-own (err u1207))
(define-constant err-deadline-not-passed (err u1208))
(define-constant err-already-claimed (err u1209))
(define-constant err-insufficient-verifications (err u1210))

;; Minimum stake amount (10 STX)
(define-constant min-stake-amount u10000000)
;; Required verifications for success
(define-constant min-verifications u3)
;; Platform fee (5% = 500 basis points)
(define-constant platform-fee-bp u500)
(define-constant basis-points u10000)

;; Data Variables
(define-data-var commitment-nonce uint u0)
(define-data-var total-commitments uint u0)
(define-data-var total-staked uint u0)
(define-data-var total-successful uint u0)
(define-data-var platform-treasury uint u0)

;; Commitment Structure
(define-map commitments
    uint
    {
        creator: principal,
        goal: (string-utf8 200),
        stake-amount: uint,
        deadline: uint,
        required-verifiers: uint,
        verification-count: uint,
        success-verified: uint,
        failure-verified: uint,
        status: (string-ascii 20),
        created-at: uint,
        completed-at: (optional uint),
        category: (string-ascii 30)
    }
)

;; Verification Records
(define-map verifications
    { commitment-id: uint, verifier: principal }
    {
        verified-success: bool,
        verified-at: uint,
        comment: (string-utf8 300)
    }
)

;; User Statistics
(define-map user-stats
    principal
    {
        total-commitments: uint,
        successful-commitments: uint,
        failed-commitments: uint,
        total-staked: uint,
        total-earned: uint,
        success-rate: uint,
        verifications-given: uint
    }
)

;; User commitment tracking
(define-map user-commitment-index
    { user: principal, index: uint }
    uint
)

(define-map user-commitment-count
    principal
    uint
)

;; Verifier tracking per commitment
(define-map commitment-verifier-index
    { commitment-id: uint, index: uint }
    principal
)

;; Read-Only Functions

(define-read-only (get-commitment (commitment-id uint))
    (ok (map-get? commitments commitment-id))
)

(define-read-only (get-verification (commitment-id uint) (verifier principal))
    (ok (map-get? verifications { commitment-id: commitment-id, verifier: verifier }))
)

(define-read-only (get-user-stats (user principal))
    (ok (map-get? user-stats user))
)

(define-read-only (get-user-commitment-count (user principal))
    (ok (default-to u0 (map-get? user-commitment-count user)))
)

(define-read-only (get-user-commitment-id (user principal) (index uint))
    (ok (map-get? user-commitment-index { user: user, index: index }))
)

(define-read-only (get-platform-stats)
    (ok {
        total-commitments: (var-get total-commitments),
        total-staked: (var-get total-staked),
        total-successful: (var-get total-successful),
        platform-treasury: (var-get platform-treasury)
    })
)

(define-read-only (calculate-success-rate (user principal))
    (let (
        (stats (default-to 
            { total-commitments: u0, successful-commitments: u0, failed-commitments: u0, total-staked: u0, total-earned: u0, success-rate: u0, verifications-given: u0 }
            (map-get? user-stats user)))
        (total (get total-commitments stats))
        (successful (get successful-commitments stats))
    )
        (if (is-eq total u0)
            (ok u0)
            (ok (/ (* successful u100) total))
        )
    )
)

(define-read-only (is-deadline-passed (commitment-id uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
    )
        (ok (> stacks-block-height (get deadline commitment)))
    )
)

;; Private Helper Functions

(define-private (add-to-user-index (user principal) (commitment-id uint))
    (let (
        (current-count (default-to u0 (map-get? user-commitment-count user)))
    )
        (map-set user-commitment-index
            { user: user, index: current-count }
            commitment-id
        )
        (map-set user-commitment-count user (+ current-count u1))
    )
)

(define-private (update-user-stats-create (user principal) (stake-amount uint))
    (let (
        (stats (default-to 
            { total-commitments: u0, successful-commitments: u0, failed-commitments: u0, total-staked: u0, total-earned: u0, success-rate: u0, verifications-given: u0 }
            (map-get? user-stats user)))
    )
        (map-set user-stats user
            (merge stats {
                total-commitments: (+ (get total-commitments stats) u1),
                total-staked: (+ (get total-staked stats) stake-amount)
            })
        )
    )
)

(define-private (update-user-stats-success (user principal) (reward uint))
    (let (
        (stats (unwrap! (map-get? user-stats user) false))
        (new-success (+ (get successful-commitments stats) u1))
        (total (get total-commitments stats))
        (new-rate (/ (* new-success u100) total))
    )
        (map-set user-stats user
            (merge stats {
                successful-commitments: new-success,
                total-earned: (+ (get total-earned stats) reward),
                success-rate: new-rate
            })
        )
        true
    )
)

(define-private (update-user-stats-failure (user principal))
    (let (
        (stats (unwrap! (map-get? user-stats user) false))
        (new-failures (+ (get failed-commitments stats) u1))
        (success (get successful-commitments stats))
        (total (get total-commitments stats))
        (new-rate (/ (* success u100) total))
    )
        (map-set user-stats user
            (merge stats {
                failed-commitments: new-failures,
                success-rate: new-rate
            })
        )
        true
    )
)

;; Public Functions

;; Create a new commitment
(define-public (create-commitment
    (goal (string-utf8 200))
    (stake-amount uint)
    (deadline-blocks uint)
    (required-verifiers uint)
    (category (string-ascii 30)))
    (let (
        (commitment-id (+ (var-get commitment-nonce) u1))
        (deadline (+ stacks-block-height deadline-blocks))
    )
        (asserts! (>= stake-amount min-stake-amount) err-invalid-amount)
        (asserts! (> deadline-blocks u0) err-invalid-amount)
        (asserts! (>= required-verifiers min-verifications) err-invalid-amount)
        (asserts! (> (len goal) u0) err-invalid-amount)
        
        ;; Lock stake in contract
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
        
        ;; Create commitment
        (map-set commitments commitment-id {
            creator: tx-sender,
            goal: goal,
            stake-amount: stake-amount,
            deadline: deadline,
            required-verifiers: required-verifiers,
            verification-count: u0,
            success-verified: u0,
            failure-verified: u0,
            status: "active",
            created-at: stacks-block-height,
            completed-at: none,
            category: category
        })
        
        ;; Add to user index
        (add-to-user-index tx-sender commitment-id)
        
        ;; Update user stats
        (update-user-stats-create tx-sender stake-amount)
        
        ;; Update global stats
        (var-set commitment-nonce commitment-id)
        (var-set total-commitments (+ (var-get total-commitments) u1))
        (var-set total-staked (+ (var-get total-staked) stake-amount))
        
        (ok commitment-id)
    )
)

;; Verify commitment completion
(define-public (verify-commitment
    (commitment-id uint)
    (success bool)
    (comment (string-utf8 300)))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (existing-verification (map-get? verifications { commitment-id: commitment-id, verifier: tx-sender }))
        (verifier-stats (default-to 
            { total-commitments: u0, successful-commitments: u0, failed-commitments: u0, total-staked: u0, total-earned: u0, success-rate: u0, verifications-given: u0 }
            (map-get? user-stats tx-sender)))
    )
        (asserts! (is-eq (get status commitment) "active") err-commitment-ended)
        (asserts! (not (is-eq tx-sender (get creator commitment))) err-cannot-verify-own)
        (asserts! (is-none existing-verification) err-already-verified)
        (asserts! (> (len comment) u0) err-invalid-amount)
        
        ;; Record verification
        (map-set verifications
            { commitment-id: commitment-id, verifier: tx-sender }
            {
                verified-success: success,
                verified-at: stacks-block-height,
                comment: comment
            }
        )
        
        ;; Update commitment counts
        (map-set commitments commitment-id
            (merge commitment {
                verification-count: (+ (get verification-count commitment) u1),
                success-verified: (if success (+ (get success-verified commitment) u1) (get success-verified commitment)),
                failure-verified: (if success (get failure-verified commitment) (+ (get failure-verified commitment) u1))
            })
        )
        
        ;; Update verifier stats
        (map-set user-stats tx-sender
            (merge verifier-stats {
                verifications-given: (+ (get verifications-given verifier-stats) u1)
            })
        )
        
        (ok true)
    )
)

;; Claim reward after successful verification
(define-public (claim-success (commitment-id uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (creator (get creator commitment))
        (stake (get stake-amount commitment))
        (success-count (get success-verified commitment))
        (required (get required-verifiers commitment))
        (platform-fee (/ (* stake platform-fee-bp) basis-points))
        (reward (- stake platform-fee))
    )
        (asserts! (is-eq tx-sender creator) err-unauthorized)
        (asserts! (is-eq (get status commitment) "active") err-already-claimed)
        (asserts! (> stacks-block-height (get deadline commitment)) err-deadline-not-passed)
        (asserts! (>= success-count required) err-insufficient-verifications)
        
        ;; Transfer reward to creator
        (try! (as-contract (stx-transfer? reward tx-sender creator)))
        
        ;; Transfer platform fee
        (try! (as-contract (stx-transfer? platform-fee tx-sender contract-owner)))
        
        ;; Update commitment status
        (map-set commitments commitment-id
            (merge commitment {
                status: "successful",
                completed-at: (some stacks-block-height)
            })
        )
        
        ;; Update user stats
        (update-user-stats-success creator reward)
        
        ;; Update global stats
        (var-set total-successful (+ (var-get total-successful) u1))
        (var-set total-staked (- (var-get total-staked) stake))
        (var-set platform-treasury (+ (var-get platform-treasury) platform-fee))
        
        (ok reward)
    )
)

;; Mark as failed if insufficient verifications
(define-public (claim-failure (commitment-id uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (creator (get creator commitment))
        (stake (get stake-amount commitment))
        (success-count (get success-verified commitment))
        (required (get required-verifiers commitment))
    )
        (asserts! (is-eq tx-sender creator) err-unauthorized)
        (asserts! (is-eq (get status commitment) "active") err-already-claimed)
        (asserts! (> stacks-block-height (get deadline commitment)) err-deadline-not-passed)
        (asserts! (< success-count required) err-insufficient-verifications)
        
        ;; Stake goes to platform (forfeited)
        (try! (as-contract (stx-transfer? stake tx-sender contract-owner)))
        
        ;; Update commitment status
        (map-set commitments commitment-id
            (merge commitment {
                status: "failed",
                completed-at: (some stacks-block-height)
            })
        )
        
        ;; Update user stats
        (update-user-stats-failure creator)
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) stake))
        (var-set platform-treasury (+ (var-get platform-treasury) stake))
        
        (ok true)
    )
)

;; Cancel commitment before deadline (small penalty)
(define-public (cancel-commitment (commitment-id uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (creator (get creator commitment))
        (stake (get stake-amount commitment))
        (penalty (/ stake u10))
        (refund (- stake penalty))
    )
        (asserts! (is-eq tx-sender creator) err-unauthorized)
        (asserts! (is-eq (get status commitment) "active") err-commitment-ended)
        (asserts! (<= stacks-block-height (get deadline commitment)) err-deadline-not-passed)
        
        ;; Refund 90% to creator
        (try! (as-contract (stx-transfer? refund tx-sender creator)))
        
        ;; 10% penalty to platform
        (try! (as-contract (stx-transfer? penalty tx-sender contract-owner)))
        
        ;; Update commitment status
        (map-set commitments commitment-id
            (merge commitment {
                status: "cancelled",
                completed-at: (some stacks-block-height)
            })
        )
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) stake))
        (var-set platform-treasury (+ (var-get platform-treasury) penalty))
        
        (ok refund)
    )
)

;; Extend deadline (pay extra fee)
(define-public (extend-deadline (commitment-id uint) (additional-blocks uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (extension-fee u1000000)
        (new-deadline (+ (get deadline commitment) additional-blocks))
    )
        (asserts! (is-eq tx-sender (get creator commitment)) err-unauthorized)
        (asserts! (is-eq (get status commitment) "active") err-commitment-ended)
        (asserts! (> additional-blocks u0) err-invalid-amount)
        
        ;; Pay extension fee
        (try! (stx-transfer? extension-fee tx-sender contract-owner))
        
        ;; Update deadline
        (map-set commitments commitment-id
            (merge commitment { deadline: new-deadline })
        )
        
        (var-set platform-treasury (+ (var-get platform-treasury) extension-fee))
        
        (ok true)
    )
)

;; Increase stake amount
(define-public (increase-stake (commitment-id uint) (additional-amount uint))
    (let (
        (commitment (unwrap! (map-get? commitments commitment-id) err-not-found))
        (current-stake (get stake-amount commitment))
    )
        (asserts! (is-eq tx-sender (get creator commitment)) err-unauthorized)
        (asserts! (is-eq (get status commitment) "active") err-commitment-ended)
        (asserts! (> additional-amount u0) err-invalid-amount)
        
        ;; Transfer additional stake
        (try! (stx-transfer? additional-amount tx-sender (as-contract tx-sender)))
        
        ;; Update commitment
        (map-set commitments commitment-id
            (merge commitment {
                stake-amount: (+ current-stake additional-amount)
            })
        )
        
        ;; Update global stats
        (var-set total-staked (+ (var-get total-staked) additional-amount))
        
        (ok true)
    )
)

;; Withdraw platform revenue
(define-public (withdraw-treasury (amount uint))
    (let (
        (treasury (var-get platform-treasury))
    )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= amount treasury) err-invalid-amount)
        (asserts! (> amount u0) err-invalid-amount)
        
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (var-set platform-treasury (- treasury amount))
        
        (ok true)
    )
)