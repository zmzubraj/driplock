// Package dripdemo is a free demo GRC20 token (DRIP) for trying Driplock.
//
// Anyone can call Faucet to receive 1,000 DRIP once per hour. The token has
// no value and exists only so people can test GRC20 vesting streams without
// spending anything.
package dripdemo

import (
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	faucetAmount   int64 = 1_000_000_000 // 1,000 DRIP at 6 decimals
	faucetCooldown int64 = 3600
)

var (
	Token      *grc20.Token
	ledger     *grc20.PrivateLedger
	userTeller grc20.Teller
	lastClaim  avl.Tree // address -> int64 unix time
	tokenKey   string
)

func init(cur realm) {
	Token, ledger = grc20.NewToken("Drip Demo", "DRIP", 6, 0, cur)
	userTeller = ledger.CallerTeller()
	tokenKey = grc20reg.Register(cross(cur), Token, "")
}

// Faucet mints 1,000 DRIP to the caller, at most once per hour.
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	now := time.Now().Unix()
	if v := lastClaim.Get(caller.String()); v != nil && now-v.(int64) < faucetCooldown {
		panic("dripdemo: faucet used less than an hour ago")
	}
	lastClaim.Set(caller.String(), now)
	if err := ledger.Mint(caller, faucetAmount); err != nil {
		panic(err)
	}
}

// Approve lets spender (for example the Driplock realm) pull amount from the caller.
func Approve(cur realm, spender address, amount int64) {
	if err := userTeller.Approve(0, cur, spender, amount); err != nil {
		panic(err)
	}
}

// Transfer moves the caller's own tokens.
func Transfer(cur realm, to address, amount int64) {
	if err := userTeller.Transfer(0, cur, to, amount); err != nil {
		panic(err)
	}
}

func BalanceOf(addr address) int64 { return Token.BalanceOf(addr) }

func Allowance(owner, spender address) int64 { return Token.Allowance(owner, spender) }

// TokenKey is the grc20reg key to pass to Driplock's CreateGRC20Stream.
func TokenKey() string { return tokenKey }

func Render(_ string) string {
	return "# Drip Demo (DRIP)\n\nA free test token for trying Driplock. Call `Faucet` for 1,000 DRIP once an hour, " +
		"`Approve` the Driplock realm, then create a GRC20 stream with the key `" + tokenKey + "`.\n\n" +
		Token.RenderHome()
}
