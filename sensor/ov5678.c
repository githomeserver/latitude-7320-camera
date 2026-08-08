// SPDX-License-Identifier: GPL-2.0
/*
 * OmniVision OV5678 sensor driver - Phase C skeleton.
 *
 * Target: the front / user-facing 5MP camera on a Dell Latitude 7320
 * Detachable. ACPI id OVTI5678, i2c 0x36 on \_SB.PC00.I2C1, CSI-2 port 6,
 * 2 lanes, MCLK 19.2 MHz. Power comes from a TPS68470 (INT3472:07); the
 * matching board data lives in this project's int3472-dell7320 DKMS module.
 *
 * WHAT THIS DOES
 *
 * Binds OVTI5678, brings up clock/regulators/GPIOs, and reads the chip id.
 * That is deliberately the whole scope: it is the milestone the engineering
 * brief sets for this phase, and passing it proves the power sequencing, the
 * rail mapping and the reset/powerdown pin assignment are all correct.
 *
 * WHAT THIS DOES NOT DO
 *
 * No mode tables, no streaming, no format/selection ops. Those need the
 * per-mode register sequences, which are not publicly available for this part
 * and are the subject of Phase D. Writing plausible-looking mode tables now
 * would be inventing data, so the subdev is registered without them and
 * s_stream is refused.
 *
 * UNVERIFIED VALUES
 *
 * OV5678_CHIP_ID below is an extrapolation from sibling parts (ov5675 reports
 * 0x005675 at 0x300a), not something read from a datasheet. The driver
 * therefore reports whatever it reads and only enforces a match when asked to
 * - see the expect_chip_id parameter. The point of the first run is to find
 * out what this sensor actually answers.
 */

#include <linux/acpi.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/machine.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/unaligned.h>
#include <media/v4l2-device.h>
#include <media/v4l2-subdev.h>

#define OV5678_REG_CHIP_ID		0x300a
#define OV5678_CHIP_ID			0x005678	/* unverified, see above */
#define OV5678_XVCLK_19_2		19200000

static unsigned int expect_chip_id = OV5678_CHIP_ID;
module_param(expect_chip_id, uint, 0644);
MODULE_PARM_DESC(expect_chip_id,
		 "chip id to require at 0x300a; 0 = report whatever is read and continue");

static unsigned int reset_us = 2000;
module_param(reset_us, uint, 0644);
MODULE_PARM_DESC(reset_us, "reset assertion time in us, after rails are up");

static unsigned int settle_us = 1500;
module_param(settle_us, uint, 0644);
MODULE_PARM_DESC(settle_us, "settling time in us between reset release and first i2c access");

static bool dump_regs = true;
module_param(dump_regs, bool, 0644);
MODULE_PARM_DESC(dump_regs, "dump identification registers on probe");

static bool sweep;
module_param(sweep, bool, 0444);
MODULE_PARM_DESC(sweep,
		 "ignore the board-data reset/powerdown mapping, drive every tps68470 line directly and report which combination makes the sensor answer");

/*
 * tps68470-gpio exposes 10 lines, but they are not equivalent. Lines 0..6 are
 * regular GPIOs backed by TPS68470_REG_GPDO. Lines 7, 8, 9 are "logic output"
 * pins backed by TPS68470_REG_SGPO - s_enable, s_idle and s_resetn - and they
 * drive the PMIC's own state machine.
 *
 * Do not sweep 7..9. Driving them wedged the TPS68470 hard enough that it
 * stopped acknowledging on i2c entirely (regulator enable then failed with
 * -EREMOTEIO and every rail read back "unknown"), and only a reboot recovered
 * it. Only the seven regular GPIOs are exposed here.
 *
 * This is a second lookup table for the same consumer; the gpiolib lookup
 * walks every registered table, so it coexists with the board-data one. The
 * named "reset"/"powerdown" descriptors are deliberately not requested in
 * sweep mode, otherwise those lines would already be busy.
 */
#define OV5678_TPS_NGPIO 7

static struct gpiod_lookup_table ov5678_sweep_gpios = {
	.dev_id = "i2c-OVTI5678:00",
	.table = {
		GPIO_LOOKUP_IDX("tps68470-gpio", 0, "tps", 0, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 1, "tps", 1, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 2, "tps", 2, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 3, "tps", 3, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 4, "tps", 4, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 5, "tps", 5, GPIO_ACTIVE_HIGH),
		GPIO_LOOKUP_IDX("tps68470-gpio", 6, "tps", 6, GPIO_ACTIVE_HIGH),
		{ }
	}
};

static const char * const ov5678_supply_names[] = {
	"dovdd",	/* digital I/O */
	"avdd",		/* analog */
	"dvdd",		/* digital core */
};

#define OV5678_NUM_SUPPLIES ARRAY_SIZE(ov5678_supply_names)

struct ov5678 {
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct i2c_client *client;
	struct device *dev;

	struct clk *xvclk;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *powerdown_gpio;
	struct gpio_desc *tps[OV5678_TPS_NGPIO];	/* sweep mode only */
	struct regulator_bulk_data supplies[OV5678_NUM_SUPPLIES];
};

static inline struct ov5678 *to_ov5678(struct v4l2_subdev *sd)
{
	return container_of(sd, struct ov5678, sd);
}

/* OmniVision parts use a 16-bit register address and big-endian values. */
static int ov5678_read_reg(struct ov5678 *sensor, u16 reg, unsigned int len, u32 *val)
{
	struct i2c_client *client = sensor->client;
	u8 data_buf[4] = { };
	struct i2c_msg msgs[2];
	u8 addr_buf[2];
	int ret;

	if (len > sizeof(data_buf))
		return -EINVAL;

	put_unaligned_be16(reg, addr_buf);

	msgs[0].addr = client->addr;
	msgs[0].flags = 0;
	msgs[0].len = sizeof(addr_buf);
	msgs[0].buf = addr_buf;

	msgs[1].addr = client->addr;
	msgs[1].flags = I2C_M_RD;
	msgs[1].len = len;
	msgs[1].buf = &data_buf[sizeof(data_buf) - len];

	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret != ARRAY_SIZE(msgs))
		return ret < 0 ? ret : -EIO;

	*val = get_unaligned_be32(data_buf);

	return 0;
}

static int ov5678_power_on(struct ov5678 *sensor)
{
	int ret;

	ret = clk_prepare_enable(sensor->xvclk);
	if (ret) {
		dev_err(sensor->dev, "failed to enable xvclk: %d\n", ret);
		return ret;
	}

	/* Hold the sensor in reset and powered down while the rails come up. */
	gpiod_set_value_cansleep(sensor->reset_gpio, 1);
	gpiod_set_value_cansleep(sensor->powerdown_gpio, 1);

	ret = regulator_bulk_enable(OV5678_NUM_SUPPLIES, sensor->supplies);
	if (ret) {
		dev_err(sensor->dev, "failed to enable regulators: %d\n", ret);
		clk_disable_unprepare(sensor->xvclk);
		return ret;
	}

	usleep_range(reset_us, reset_us + 200);

	gpiod_set_value_cansleep(sensor->powerdown_gpio, 0);
	gpiod_set_value_cansleep(sensor->reset_gpio, 0);

	usleep_range(settle_us, settle_us + 100);

	return 0;
}

static void ov5678_power_off(struct ov5678 *sensor)
{
	gpiod_set_value_cansleep(sensor->reset_gpio, 1);
	gpiod_set_value_cansleep(sensor->powerdown_gpio, 1);
	regulator_bulk_disable(OV5678_NUM_SUPPLIES, sensor->supplies);
	clk_disable_unprepare(sensor->xvclk);
}

static int ov5678_runtime_resume(struct device *dev)
{
	return ov5678_power_on(to_ov5678(dev_get_drvdata(dev)));
}

static int ov5678_runtime_suspend(struct device *dev)
{
	ov5678_power_off(to_ov5678(dev_get_drvdata(dev)));
	return 0;
}

/*
 * Read the identification registers and say what we found. Returns 0 if the
 * sensor answered at all; enforcement of a particular id is separate, so that
 * a wrong guess at OV5678_CHIP_ID does not look like a power failure.
 */
static int ov5678_identify(struct ov5678 *sensor)
{
	u32 id = 0;
	int ret;

	ret = ov5678_read_reg(sensor, OV5678_REG_CHIP_ID, 3, &id);
	if (ret) {
		dev_err(sensor->dev,
			"no answer at i2c 0x%02x reading 0x%04x: %d - sensor is not powered, or reset/powerdown is wrong\n",
			sensor->client->addr, OV5678_REG_CHIP_ID, ret);
		return ret;
	}

	dev_info(sensor->dev, "chip id at 0x%04x reads 0x%06x\n",
		 OV5678_REG_CHIP_ID, id);

	if (dump_regs) {
		static const u16 regs[] = { 0x300a, 0x300b, 0x300c, 0x302a, 0x0000 };
		unsigned int i;
		u32 val;

		for (i = 0; i < ARRAY_SIZE(regs); i++) {
			if (ov5678_read_reg(sensor, regs[i], 1, &val) == 0)
				dev_info(sensor->dev, "  reg 0x%04x = 0x%02x\n",
					 regs[i], val);
		}
	}

	if (expect_chip_id && id != expect_chip_id) {
		dev_warn(sensor->dev,
			 "chip id 0x%06x does not match expected 0x%06x; continuing anyway (set expect_chip_id=0 to silence)\n",
			 id, expect_chip_id);
	}

	return 0;
}

/* Quiet probe of the chip id register; returns 0 if the sensor acknowledged. */
static int ov5678_try_read(struct ov5678 *sensor, u32 *id)
{
	*id = 0;
	return ov5678_read_reg(sensor, OV5678_REG_CHIP_ID, 3, id);
}

static void ov5678_set_all(struct ov5678 *sensor, int value)
{
	unsigned int i;

	for (i = 0; i < OV5678_TPS_NGPIO; i++)
		if (sensor->tps[i])
			gpiod_set_value_cansleep(sensor->tps[i], value);
}

/*
 * Walk the tps68470 lines looking for a state in which the sensor answers.
 * Rails and clock are already up when this runs, so anything found here is a
 * reset/powerdown wiring answer, not a power answer. If nothing answers in any
 * combination, the problem is upstream of the GPIOs - most likely the rail map.
 */
/*
 * The TPS68470 can be wedged by driving the wrong line, and once it stops
 * acknowledging on i2c every later result is meaningless. Probe it between
 * steps by reading a rail voltage back through its regmap.
 */
static bool ov5678_pmic_alive(struct ov5678 *sensor)
{
	return regulator_get_voltage(sensor->supplies[0].consumer) >= 0;
}

static void ov5678_run_sweep(struct ov5678 *sensor)
{
	unsigned int i, n = 0;
	int ret;
	u32 id;

	/*
	 * Acquire only now, with the rails already enabled, and only the seven
	 * regular GPIOs. See the comment on ov5678_sweep_gpios.
	 */
	for (i = 0; i < OV5678_TPS_NGPIO; i++) {
		sensor->tps[i] = devm_gpiod_get_index_optional(sensor->dev, "tps", i,
							       GPIOD_OUT_HIGH);
		if (IS_ERR(sensor->tps[i])) {
			dev_err(sensor->dev, "getting tps line %u: %ld\n",
				i, PTR_ERR(sensor->tps[i]));
			sensor->tps[i] = NULL;
			continue;
		}
		if (sensor->tps[i])
			n++;

		if (!ov5678_pmic_alive(sensor)) {
			dev_err(sensor->dev,
				"pmic stopped responding while acquiring line %u - aborting\n", i);
			return;
		}
	}

	dev_info(sensor->dev, "sweep: acquired %u of %u regular tps68470 lines\n",
		 n, OV5678_TPS_NGPIO);
	if (!n)
		return;

	dev_info(sensor->dev, "sweep: rails and clock are up, trying gpio states\n");

	/* Everything released. Most reset/powerdown lines are active low. */
	ov5678_set_all(sensor, 1);
	usleep_range(settle_us, settle_us + 100);
	ret = ov5678_try_read(sensor, &id);
	dev_info(sensor->dev, "sweep: all lines HIGH -> %s (0x%06x)\n",
		 ret ? "no answer" : "ANSWERED", id);
	if (!ret)
		return;

	ov5678_set_all(sensor, 0);
	usleep_range(settle_us, settle_us + 100);
	ret = ov5678_try_read(sensor, &id);
	dev_info(sensor->dev, "sweep: all lines LOW  -> %s (0x%06x)\n",
		 ret ? "no answer" : "ANSWERED", id);
	if (!ret)
		return;

	/* One line low, the rest high - the usual "this pin is reset" shape. */
	for (i = 0; i < OV5678_TPS_NGPIO; i++) {
		if (!sensor->tps[i])
			continue;

		ov5678_set_all(sensor, 1);
		gpiod_set_value_cansleep(sensor->tps[i], 0);
		usleep_range(reset_us, reset_us + 200);
		gpiod_set_value_cansleep(sensor->tps[i], 1);
		usleep_range(settle_us, settle_us + 100);

		ret = ov5678_try_read(sensor, &id);
		dev_info(sensor->dev, "sweep: pulsed line %u low -> %s (0x%06x)\n",
			 i, ret ? "no answer" : "ANSWERED", id);
		if (!ret)
			return;

		if (!ov5678_pmic_alive(sensor)) {
			dev_err(sensor->dev,
				"pmic stopped responding after line %u - aborting\n", i);
			return;
		}
	}

	/* And the inverse, in case a line is an active-high enable. */
	for (i = 0; i < OV5678_TPS_NGPIO; i++) {
		if (!sensor->tps[i])
			continue;

		ov5678_set_all(sensor, 0);
		gpiod_set_value_cansleep(sensor->tps[i], 1);
		usleep_range(settle_us, settle_us + 100);

		ret = ov5678_try_read(sensor, &id);
		dev_info(sensor->dev, "sweep: only line %u HIGH -> %s (0x%06x)\n",
			 i, ret ? "no answer" : "ANSWERED", id);
		if (!ret)
			return;
	}

	dev_warn(sensor->dev,
		 "sweep: no gpio state produced an answer - suspect the rail map (try rail_map=1 on the int3472 module) or the i2c address\n");
}

static int ov5678_s_stream(struct v4l2_subdev *sd, int enable)
{
	/*
	 * Streaming needs the per-mode register sequences, which do not exist
	 * publicly for this part yet. Refuse rather than pretend.
	 */
	return enable ? -EOPNOTSUPP : 0;
}

static const struct v4l2_subdev_video_ops ov5678_video_ops = {
	.s_stream = ov5678_s_stream,
};

static const struct v4l2_subdev_ops ov5678_subdev_ops = {
	.video = &ov5678_video_ops,
};

static int ov5678_get_resources(struct ov5678 *sensor)
{
	struct device *dev = sensor->dev;
	unsigned long rate;
	unsigned int i;
	int ret;

	/*
	 * On this platform the clock comes from the TPS68470, which registers
	 * its clkdev with dev_id "i2c-OVTI5678:00" and a NULL con_id, so a
	 * NULL con_id lookup here is what matches.
	 */
	sensor->xvclk = devm_clk_get(dev, NULL);
	if (IS_ERR(sensor->xvclk))
		return dev_err_probe(dev, PTR_ERR(sensor->xvclk),
				     "getting xvclk\n");

	rate = clk_get_rate(sensor->xvclk);
	if (rate != OV5678_XVCLK_19_2)
		dev_warn(dev, "xvclk is %lu Hz, expected %u Hz\n",
			 rate, OV5678_XVCLK_19_2);

	/*
	 * Requested unconditionally, unlike ov8856.c which skips this on ACPI.
	 * The TPS68470 board data supplies these by name, so skipping would
	 * leave the sensor unpowered.
	 */
	if (sweep) {
		/*
		 * Lines are acquired later, from inside the sweep, so that
		 * nothing is driven until the rails are already up. Acquiring
		 * them here with GPIOD_OUT_HIGH is what broke the PMIC before.
		 */
	} else {
		sensor->reset_gpio = devm_gpiod_get_optional(dev, "reset",
							     GPIOD_OUT_HIGH);
		if (IS_ERR(sensor->reset_gpio))
			return dev_err_probe(dev, PTR_ERR(sensor->reset_gpio),
					     "getting reset gpio\n");
		if (!sensor->reset_gpio)
			dev_warn(dev, "no reset gpio mapped\n");

		sensor->powerdown_gpio = devm_gpiod_get_optional(dev, "powerdown",
								 GPIOD_OUT_HIGH);
		if (IS_ERR(sensor->powerdown_gpio))
			return dev_err_probe(dev, PTR_ERR(sensor->powerdown_gpio),
					     "getting powerdown gpio\n");
		if (!sensor->powerdown_gpio)
			dev_warn(dev, "no powerdown gpio mapped\n");
	}

	for (i = 0; i < OV5678_NUM_SUPPLIES; i++)
		sensor->supplies[i].supply = ov5678_supply_names[i];

	ret = devm_regulator_bulk_get(dev, OV5678_NUM_SUPPLIES, sensor->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "getting regulators\n");

	return 0;
}

static int ov5678_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct ov5678 *sensor;
	int ret;

	sensor = devm_kzalloc(dev, sizeof(*sensor), GFP_KERNEL);
	if (!sensor)
		return -ENOMEM;

	sensor->client = client;
	sensor->dev = dev;

	v4l2_i2c_subdev_init(&sensor->sd, client, &ov5678_subdev_ops);

	ret = ov5678_get_resources(sensor);
	if (ret)
		return ret;

	ret = ov5678_power_on(sensor);
	if (ret)
		return ret;

	if (sweep) {
		ov5678_run_sweep(sensor);
		/*
		 * Sweep mode is a measurement, not a working bind. Fail the
		 * probe so power drops and the run can be repeated cleanly.
		 */
		ret = -ENODEV;
		goto err_power_off;
	}

	ret = ov5678_identify(sensor);
	if (ret)
		goto err_power_off;

	sensor->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	sensor->pad.flags = MEDIA_PAD_FL_SOURCE;
	sensor->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;

	ret = media_entity_pads_init(&sensor->sd.entity, 1, &sensor->pad);
	if (ret) {
		dev_err(dev, "failed to init media entity: %d\n", ret);
		goto err_power_off;
	}

	/*
	 * Registering the subdev needs an endpoint in the fwnode graph, which
	 * ipu-bridge only creates once OVTI5678 is in ipu_supported_sensors[]
	 * (Phase B). Until then this returns -ENODEV or waits; that is not a
	 * reason to fail the probe, since the chip id result above is the
	 * thing being measured.
	 */
	ret = v4l2_async_register_subdev_sensor(&sensor->sd);
	if (ret)
		dev_warn(dev, "subdev not registered (%d) - expected until the ipu-bridge entry exists\n",
			 ret);

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);
	pm_runtime_idle(dev);

	dev_info(dev, "probed\n");

	return 0;

err_power_off:
	ov5678_power_off(sensor);
	return ret;
}

static void ov5678_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct ov5678 *sensor = to_ov5678(sd);

	v4l2_async_unregister_subdev(sd);
	media_entity_cleanup(&sd->entity);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev))
		ov5678_power_off(sensor);
	pm_runtime_set_suspended(&client->dev);
}

static const struct dev_pm_ops ov5678_pm_ops = {
	SET_RUNTIME_PM_OPS(ov5678_runtime_suspend, ov5678_runtime_resume, NULL)
};

static const struct acpi_device_id ov5678_acpi_ids[] = {
	{ "OVTI5678" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, ov5678_acpi_ids);

static struct i2c_driver ov5678_i2c_driver = {
	.driver = {
		.name = "ov5678",
		.pm = &ov5678_pm_ops,
		.acpi_match_table = ov5678_acpi_ids,
	},
	.probe = ov5678_probe,
	.remove = ov5678_remove,
};

static int __init ov5678_init(void)
{
	if (sweep)
		gpiod_add_lookup_table(&ov5678_sweep_gpios);

	return i2c_add_driver(&ov5678_i2c_driver);
}
module_init(ov5678_init);

static void __exit ov5678_exit(void)
{
	i2c_del_driver(&ov5678_i2c_driver);

	if (sweep)
		gpiod_remove_lookup_table(&ov5678_sweep_gpios);
}
module_exit(ov5678_exit);

MODULE_DESCRIPTION("OmniVision OV5678 sensor driver");
MODULE_LICENSE("GPL v2");
