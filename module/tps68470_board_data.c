// SPDX-License-Identifier: GPL-2.0
/*
 * TI TPS68470 PMIC platform data for the Dell Latitude 7320 Detachable.
 *
 * This machine has two MIPI sensors behind an Intel IPU6, both powered by a
 * single TPS68470 (ACPI INT3472:07, \_SB.PC00.CLP0, _DDN "PMIC-CRDG"):
 *
 *   OVTI5678:00  front / user-facing, 5MP, CSI-2 port 6, 2 lanes, i2c 0x36 on I2C1
 *   OVTI8856:00  rear  / world-facing, 8MP, CSI-2 port 1, 4 lanes, i2c 0x36 on I2C2
 *
 * MCLK for both is 19.2 MHz (ACPI NVS L0CK/L1CK = 0x0124F800), and both name
 * control logic id 0, which matches CLDB.control_logic_id.
 *
 * WHAT IS VERIFIED AND WHAT IS NOT
 *
 * Verified by reading this machine's ACPI NVS at runtime: the DMI strings, the
 * control logic instance (INT3472:07 -> "i2c-INT3472:07"), the sensor ACPI ids,
 * and everything in the table above.
 *
 * NOT verified: which TPS68470 GPIO drives reset/powerdown for each sensor, and
 * which rail feeds which sensor supply. CLDB carries C0W0=14 and C0W4=3 at
 * offsets 0x08/0x0c, but tps68470-gpio only has pins 0..9, so 14 cannot be a
 * pin number and the CLDB bytes cannot be read as a lookup table directly.
 * Both are therefore module parameters so they can be swept by unbind/rebind
 * rather than by rebuilding and rebooting. See the README.
 */

#include <linux/dmi.h>
#include <linux/gpio/machine.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/platform_data/tps68470.h>
#include <linux/regulator/machine.h>
#include "tps68470.h"

#define OV5678_DEV_ID	"i2c-OVTI5678:00"
#define OV8856_DEV_ID	"i2c-OVTI8856:00"

/* -1 disables a lookup entirely; otherwise a tps68470-gpio pin, 0..9. */
static int front_reset = 9;
static int front_powerdown = 7;
static int rear_reset = 3;
static int rear_powerdown = 4;
static int rail_map;

module_param(front_reset, int, 0644);
MODULE_PARM_DESC(front_reset, "tps68470-gpio pin for OVTI5678 reset, -1 to omit");
module_param(front_powerdown, int, 0644);
MODULE_PARM_DESC(front_powerdown, "tps68470-gpio pin for OVTI5678 powerdown, -1 to omit");
module_param(rear_reset, int, 0644);
MODULE_PARM_DESC(rear_reset, "tps68470-gpio pin for OVTI8856 reset, -1 to omit");
module_param(rear_powerdown, int, 0644);
MODULE_PARM_DESC(rear_powerdown, "tps68470-gpio pin for OVTI8856 powerdown, -1 to omit");
module_param(rail_map, int, 0644);
MODULE_PARM_DESC(rail_map,
		 "0 = ANA/CORE/VSIO -> avdd/dvdd/dovdd (conventional), 1 = VSIO/AUX1/AUX2 -> avdd/dvdd/dovdd (Dell 7212 style)");

/*
 * Rail map 0 - the conventional OmniVision supply set, at the voltages those
 * parts expect: AVDD 2.8V, DVDD 1.2V, DOVDD 1.8V.
 */
static struct regulator_consumer_supply dell_7320_core_consumers[] = {
	REGULATOR_SUPPLY("dvdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("dvdd", OV8856_DEV_ID),
};

static struct regulator_consumer_supply dell_7320_ana_consumers[] = {
	REGULATOR_SUPPLY("avdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("avdd", OV8856_DEV_ID),
};

static struct regulator_consumer_supply dell_7320_vsio_consumers[] = {
	REGULATOR_SUPPLY("dovdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("dovdd", OV8856_DEV_ID),
};

/* Only the rear module has a VCM (ACPI NVS L1VC=2; L0VC=0 for the front). */
static struct regulator_consumer_supply dell_7320_vcm_consumers[] = {
	REGULATOR_SUPPLY("vdd", OV8856_DEV_ID "-VCM"),
};

/*
 * Rail map 1 - the mapping upstream uses for the Dell 7212, where the sensor
 * supplies hang off VSIO/AUX1/AUX2 instead. Kept selectable because this board
 * is a different CRD revision and the wiring is not documented anywhere.
 */
static struct regulator_consumer_supply dell_7320_alt_vsio_consumers[] = {
	REGULATOR_SUPPLY("avdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("avdd", OV8856_DEV_ID),
};

static struct regulator_consumer_supply dell_7320_alt_aux1_consumers[] = {
	REGULATOR_SUPPLY("dvdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("dvdd", OV8856_DEV_ID),
};

static struct regulator_consumer_supply dell_7320_alt_aux2_consumers[] = {
	REGULATOR_SUPPLY("dovdd", OV5678_DEV_ID),
	REGULATOR_SUPPLY("dovdd", OV8856_DEV_ID),
};

#define DELL_7320_REG(_name, _uV, _consumers)					\
static const struct regulator_init_data _name = {				\
	.constraints = {							\
		.min_uV = (_uV),						\
		.max_uV = (_uV),						\
		.apply_uV = 1,							\
		.valid_ops_mask = REGULATOR_CHANGE_STATUS,			\
	},									\
	.num_consumer_supplies = ARRAY_SIZE(_consumers),			\
	.consumer_supplies = (_consumers),					\
}

#define DELL_7320_REG_UNUSED(_name, _uV)					\
static const struct regulator_init_data _name = {				\
	.constraints = {							\
		.min_uV = (_uV),						\
		.max_uV = (_uV),						\
		.apply_uV = 1,							\
		.valid_ops_mask = REGULATOR_CHANGE_STATUS,			\
	},									\
	.num_consumer_supplies = 0,						\
	.consumer_supplies = NULL,						\
}

DELL_7320_REG(dell_7320_core_reg, 1200000, dell_7320_core_consumers);
DELL_7320_REG(dell_7320_ana_reg, 2815200, dell_7320_ana_consumers);
DELL_7320_REG(dell_7320_vcm_reg, 2815200, dell_7320_vcm_consumers);
DELL_7320_REG(dell_7320_vsio_reg, 1800600, dell_7320_vsio_consumers);
DELL_7320_REG_UNUSED(dell_7320_aux1_reg, 1213200);
DELL_7320_REG_UNUSED(dell_7320_aux2_reg, 1800600);

DELL_7320_REG_UNUSED(dell_7320_alt_core_reg, 1200000);
DELL_7320_REG_UNUSED(dell_7320_alt_ana_reg, 2815200);
DELL_7320_REG(dell_7320_alt_vsio_reg, 1800600, dell_7320_alt_vsio_consumers);
DELL_7320_REG(dell_7320_alt_aux1_reg, 1213200, dell_7320_alt_aux1_consumers);
DELL_7320_REG(dell_7320_alt_aux2_reg, 1800600, dell_7320_alt_aux2_consumers);

/* VIO is always-on and must track VSIO. */
static const struct regulator_init_data dell_7320_vio_reg = {
	.constraints = {
		.min_uV = 1800600,
		.max_uV = 1800600,
		.apply_uV = 1,
		.always_on = 1,
	},
};

static const struct tps68470_regulator_platform_data dell_7320_pdata = {
	.reg_init_data = {
		[TPS68470_CORE] = &dell_7320_core_reg,
		[TPS68470_ANA]  = &dell_7320_ana_reg,
		[TPS68470_VCM]  = &dell_7320_vcm_reg,
		[TPS68470_VIO]  = &dell_7320_vio_reg,
		[TPS68470_VSIO] = &dell_7320_vsio_reg,
		[TPS68470_AUX1] = &dell_7320_aux1_reg,
		[TPS68470_AUX2] = &dell_7320_aux2_reg,
	},
};

static const struct tps68470_regulator_platform_data dell_7320_alt_pdata = {
	.reg_init_data = {
		[TPS68470_CORE] = &dell_7320_alt_core_reg,
		[TPS68470_ANA]  = &dell_7320_alt_ana_reg,
		[TPS68470_VCM]  = &dell_7320_vcm_reg,
		[TPS68470_VIO]  = &dell_7320_vio_reg,
		[TPS68470_VSIO] = &dell_7320_alt_vsio_reg,
		[TPS68470_AUX1] = &dell_7320_alt_aux1_reg,
		[TPS68470_AUX2] = &dell_7320_alt_aux2_reg,
	},
};

/*
 * Two slots plus a terminator each. The pin numbers below are placeholders;
 * dell_7320_apply_gpio_params() rewrites them from the module parameters on
 * every lookup, which happens once per probe.
 */
static struct gpiod_lookup_table dell_7320_ov5678_gpios = {
	.dev_id = OV5678_DEV_ID,
	.table = {
		GPIO_LOOKUP("tps68470-gpio", 0, "reset", GPIO_ACTIVE_LOW),
		GPIO_LOOKUP("tps68470-gpio", 0, "powerdown", GPIO_ACTIVE_LOW),
		{ }
	}
};

static struct gpiod_lookup_table dell_7320_ov8856_gpios = {
	.dev_id = OV8856_DEV_ID,
	.table = {
		GPIO_LOOKUP("tps68470-gpio", 0, "reset", GPIO_ACTIVE_LOW),
		GPIO_LOOKUP("tps68470-gpio", 0, "powerdown", GPIO_ACTIVE_LOW),
		{ }
	}
};

static void dell_7320_fill_table(struct gpiod_lookup_table *table,
				 int reset_pin, int powerdown_pin)
{
	struct gpiod_lookup entry;
	unsigned int i = 0;

	if (reset_pin >= 0) {
		entry = (struct gpiod_lookup)
			GPIO_LOOKUP("tps68470-gpio", reset_pin, "reset", GPIO_ACTIVE_LOW);
		table->table[i++] = entry;
	}

	if (powerdown_pin >= 0) {
		entry = (struct gpiod_lookup)
			GPIO_LOOKUP("tps68470-gpio", powerdown_pin, "powerdown", GPIO_ACTIVE_LOW);
		table->table[i++] = entry;
	}

	memset(&table->table[i], 0, sizeof(table->table[i]));
}

static void dell_7320_apply_gpio_params(void)
{
	dell_7320_fill_table(&dell_7320_ov5678_gpios, front_reset, front_powerdown);
	dell_7320_fill_table(&dell_7320_ov8856_gpios, rear_reset, rear_powerdown);
}

static struct int3472_tps68470_board_data dell_7320_board_data = {
	/*
	 * The live control logic on this machine is CLP0, which enumerates as
	 * INT3472:07 - not :05 as on the Dell 7212. A mismatch here produces no
	 * error message, just the -ENODEV this entry exists to fix.
	 */
	.dev_name = "i2c-INT3472:07",
	.tps68470_regulator_pdata = &dell_7320_pdata,
	.n_gpiod_lookups = 2,
	.tps68470_gpio_lookup_tables = {
		&dell_7320_ov5678_gpios,
		&dell_7320_ov8856_gpios,
	},
};

static const struct dmi_system_id int3472_tps68470_board_data_table[] = {
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Dell Inc."),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "Latitude 7320 Detachable"),
		},
		.driver_data = (void *)&dell_7320_board_data,
	},
	{ }
};

const struct int3472_tps68470_board_data *int3472_tps68470_get_board_data(const char *dev_name)
{
	struct int3472_tps68470_board_data *board_data;
	const struct dmi_system_id *match;

	for (match = dmi_first_match(int3472_tps68470_board_data_table);
	     match;
	     match = dmi_first_match(match + 1)) {
		board_data = match->driver_data;
		if (strcmp(board_data->dev_name, dev_name) == 0) {
			/*
			 * Re-read the tunables here rather than at module init,
			 * so a new mapping can be tried with an unbind/rebind
			 * instead of a rebuild and reboot.
			 */
			dell_7320_apply_gpio_params();
			board_data->tps68470_regulator_pdata =
				rail_map ? &dell_7320_alt_pdata : &dell_7320_pdata;
			return board_data;
		}
	}

	return NULL;
}
