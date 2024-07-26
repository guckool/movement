module atomic_bridge::atomic_bridge_initiator {
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::{Self, Account};
    use aptos_framework::timestamp;
    use aptos_std::aptos_hash;
    use std::signer;
    use std::vector;
    use std::bcs;

    /// Constants to represent the state of a bridge transfer
    const INITIALIZED: u8 = 0;
    const COMPLETED: u8 = 1;
    const REFUNDED: u8 = 2;

    /// A struct to hold the details of a bridge transfer
    struct BridgeTransfer has key, store {
        amount: u64,
        originator: address,
        recipient: vector<u8>, // eth address
        hash_lock: vector<u8>,
        time_lock: u64,
        state: u8,
    }

    struct BridgeTransferStore has key, store {
        transfers: vector<BridgeTransfer>,
        nonce: u64,
        bridge_transfer_initiated_events: EventHandle<BridgeTransferInitiatedEvent>,
        bridge_transfer_completed_events: EventHandle<BridgeTransferCompletedEvent>,
        bridge_transfer_refunded_events: EventHandle<BridgeTransferRefundedEvent>,
    }

    /// Event triggered upon initiating a bridge transfer
    struct BridgeTransferInitiatedEvent has store, drop {
        bridge_transfer_id: vector<u8>,
        originator: address,
        recipient: vector<u8>,
        amount: u64,
        hash_lock: vector<u8>,
        time_lock: u64,
    }

    /// Event triggered upon completing a bridge transfer
    struct BridgeTransferCompletedEvent has store, drop {
        bridge_transfer_id: vector<u8>,
        pre_image: vector<u8>,
    }

    /// Event triggered upon refunding a bridge transfer
    struct BridgeTransferRefundedEvent has store, drop {
        bridge_transfer_id: vector<u8>,
    }

    public fun initialize(account: &signer) {
        let addr = signer::address_of(account);
        if (!exists<BridgeTransferStore>(addr)) {
            move_to(account, BridgeTransferStore {
                transfers: vector::empty<BridgeTransfer>(),
                nonce: 0,
                bridge_transfer_initiated_events: account::new_event_handle<BridgeTransferInitiatedEvent>(account),
                bridge_transfer_completed_events: account::new_event_handle<BridgeTransferCompletedEvent>(account),
                bridge_transfer_refunded_events: account::new_event_handle<BridgeTransferRefundedEvent>(account),
            });
        }
    }

    public fun initiate_bridge_transfer(
        account: &signer,
        recipient: vector<u8>,
        hash_lock: vector<u8>,
        time_lock: u64,
        amount: u64
    ): vector<u8> acquires BridgeTransferStore {
        let addr = signer::address_of(account);
        let store = borrow_global_mut<BridgeTransferStore>(addr);
        store.nonce = store.nonce + 1;

        // Create a single byte vector by concatenating all components
        let combined_bytes = vector::empty<u8>();
        vector::append(&mut combined_bytes, bcs::to_bytes(&addr));
        vector::append(&mut combined_bytes, recipient);
        vector::append(&mut combined_bytes, hash_lock);
        vector::append(&mut combined_bytes, bcs::to_bytes(&store.nonce));

        let bridge_transfer_id = aptos_hash::keccak256(combined_bytes);

        let bridge_transfer = BridgeTransfer {
            amount: amount,
            originator: addr,
            recipient: recipient,
            hash_lock: hash_lock,
            time_lock: timestamp::now_seconds() + time_lock,
            state: INITIALIZED,
        };

        vector::push_back(&mut store.transfers, bridge_transfer);

        event::emit_event(&mut store.bridge_transfer_initiated_events, BridgeTransferInitiatedEvent {
            bridge_transfer_id: bridge_transfer_id,
            originator: addr,
            recipient: recipient,
            amount: amount,
            hash_lock: hash_lock,
            time_lock: timestamp::now_seconds() + time_lock,
        });

        bridge_transfer_id
    }

    public fun complete_bridge_transfer(
        account: &signer,
        bridge_transfer_id: vector<u8>,
        pre_image: vector<u8>
    ) acquires BridgeTransferStore {
        let addr = signer::address_of(account);
        let store = borrow_global_mut<BridgeTransferStore>(addr);
        let idx = get_bridge_transfer_index(&store.transfers, &bridge_transfer_id);
        let bridge_transfer = vector::borrow_mut(&mut store.transfers, idx);

        assert!(bridge_transfer.state == INITIALIZED, 1);
        assert!(aptos_hash::keccak256(pre_image) == bridge_transfer.hash_lock, 2);
        assert!(timestamp::now_seconds() <= bridge_transfer.time_lock, 3);

        bridge_transfer.state = COMPLETED;

        event::emit_event(&mut store.bridge_transfer_completed_events, BridgeTransferCompletedEvent {
            bridge_transfer_id: bridge_transfer_id,
            pre_image: pre_image,
        });
    }

    public fun refund_bridge_transfer(account: &signer, bridge_transfer_id: vector<u8>) acquires BridgeTransferStore {
        let addr = signer::address_of(account);
        let store = borrow_global_mut<BridgeTransferStore>(addr);
        let idx = get_bridge_transfer_index(&store.transfers, &bridge_transfer_id);
        let bridge_transfer = vector::borrow_mut(&mut store.transfers, idx);

        assert!(bridge_transfer.state == INITIALIZED, 1);
        assert!(timestamp::now_seconds() > bridge_transfer.time_lock, 2);

        bridge_transfer.state = REFUNDED;

        event::emit_event(&mut store.bridge_transfer_refunded_events, BridgeTransferRefundedEvent {
            bridge_transfer_id: bridge_transfer_id,
        });
    }

    /// Helper function to find the index of a bridge transfer in the transfers vector
    public fun get_bridge_transfer_index(transfers: &vector<BridgeTransfer>, bridge_transfer_id: &vector<u8>): u64 {
        let len = vector::length(transfers);
        let i = 0;
        while (i < len) {
            let transfer = vector::borrow(transfers, i);

            // Create a single byte vector by concatenating all components
            let combined_bytes = vector::empty<u8>();
            vector::append(&mut combined_bytes, bcs::to_bytes(&transfer.originator));
            vector::append(&mut combined_bytes, transfer.recipient);
            vector::append(&mut combined_bytes, transfer.hash_lock);
            vector::append(&mut combined_bytes, bcs::to_bytes(&i));

            let id = aptos_hash::keccak256(combined_bytes);
            if (id == *bridge_transfer_id) {
                break
            };
            i = i + 1;
        };
        i 
    }
}
