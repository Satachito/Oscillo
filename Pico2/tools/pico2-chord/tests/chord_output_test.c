#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../chord_output.c"

int main(void)
{
    // Two unrelated enabled slices must survive chord startup.
    mock_pwm.en = (1u << 6) | (1u << 7);
    mock_pwm.slice[6] = (mock_pwm_slice){.config={.divider=3,.top=49999},.a=25000};
    mock_pwm_slice calibration = mock_pwm.slice[6];
    chord_output_init();
    assert(mock_pwm.en == 0xcf);
    assert(mock_pwm_pin_mask == 0xff);
    assert(memcmp(&calibration, &mock_pwm.slice[6], sizeof calibration)==0);
    assert(pwm_gpio_to_slice_num(28) == 6);

    const double expected[] = {261.6255653, 311.1269837, 369.9944227, 440.0};
    for (uint i=0; i<4; ++i) {
        mock_pwm_slice slice=mock_pwm.slice[i];
        uint32_t period=(uint32_t)slice.config.top+1;
        double frequency=clock_get_hz(clk_sys)/(double)(slice.config.divider*period);
        assert(fabs(frequency-expected[i]) < 0.01);
        assert(period%2==0 && slice.a==period/2 && slice.b==period/2);
        assert(!slice.config.invert_a && slice.config.invert_b);
        uint highs_a=0, highs_b=0;
        for (uint count=0; count<period; ++count) {
            bool a=(count<slice.a)^slice.config.invert_a;
            bool b=(count<slice.b)^slice.config.invert_b;
            assert(a != b);
            highs_a += a; highs_b += b;
        }
        assert(highs_a==highs_b);
        printf("Chord GPIO%u/%u: %.6f Hz, 50%% complementary\n",2*i,2*i+1,frequency);
    }
    puts("Chord: 4 note pairs, pin mux and PWM slice isolation passed");
}
